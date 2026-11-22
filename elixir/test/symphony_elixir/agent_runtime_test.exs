defmodule SymphonyElixir.AgentRuntimeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.Runtime, as: CodexRuntime
  alias SymphonyElixir.Config.Schema

  defmodule TestRuntime do
    @behaviour SymphonyElixir.AgentRuntime

    @impl true
    def start_session(workspace, _opts) do
      {:ok, resource} =
        Task.start_link(fn ->
          receive do
            :stop -> :ok
          end
        end)

      {:ok, %{workspace: workspace, resource: resource}}
    end

    @impl true
    def run_turn(session, prompt, issue, opts) do
      opts[:on_message].(%{event: :turn_started, timestamp: DateTime.utc_now()})

      send(SymphonyElixir.AgentRuntimeTest, {:test_turn_started, self(), session, prompt, issue.id})

      receive do
        :require_approval -> {:blocked, {:approval_required, "test runtime requires approval"}}
      end
    end

    @impl true
    def stop_session(%{resource: resource}) do
      send(resource, :stop)
      :ok
    end
  end

  test "workflow defaults to Codex and accepts an explicit Codex runtime" do
    assert {:ok, %{agent: %{runtime: "codex"}}} = Schema.parse(%{})
    assert {:ok, %{agent: %{runtime: "codex"}}} = Schema.parse(%{"agent" => %{"runtime" => "codex"}})
  end

  test "workflow validation reports unknown agent runtimes" do
    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{"agent" => %{"runtime" => "unknown"}})

    assert message =~ "agent.runtime"
  end

  test "Codex reports a failed turn from its completion notification" do
    assert {{:error, {:turn_failed, %{"turn" => %{"status" => "failed"}}}}, events} =
             run_completed_codex_turn("failed")

    assert :turn_failed in events
    refute :turn_completed in events
  end

  test "Codex reports an interrupted turn as cancelled" do
    assert {{:cancelled, {:turn_cancelled, %{"turn" => %{"status" => "interrupted"}}}}, events} =
             run_completed_codex_turn("interrupted")

    assert :turn_cancelled in events
    refute :turn_completed in events
  end

  test "Codex adapts an operator input request to a blocked outcome" do
    {outcome, events} = run_codex_turn(%{"method" => "mcpServer/elicitation/request", "id" => 4, "params" => %{}})

    assert {:blocked, {:input_required, "codex turn requires operator input"}} = outcome
    assert :turn_input_required in events
  end

  test "Codex adapts an approval request to a blocked outcome" do
    {outcome, events} = run_codex_turn(%{"method" => "item/fileChange/requestApproval", "id" => 4, "params" => %{}})

    assert {:blocked, {:approval_required, "codex turn requires approval"}} = outcome
    assert :approval_required in events
  end

  test "Codex normalizes reported metrics and omits malformed token counts" do
    timestamp = DateTime.utc_now()
    limits = %{"limit_id" => "codex", "primary" => %{"used_percent" => 10}}

    assert %{
             event: :turn_completed,
             timestamp: ^timestamp,
             process_id: "42",
             rate_limits: ^limits,
             usage: %{input_tokens: 12, total_tokens: 20} = usage
           } =
             CodexRuntime.normalize_update(%{
               event: :turn_completed,
               timestamp: timestamp,
               codex_app_server_pid: 42,
               payload: %{
                 "method" => "turn/completed",
                 "usage" => %{"input_tokens" => "12", "output_tokens" => "unreported", "total_tokens" => 20},
                 "rate_snapshots" => [nil, limits]
               }
             })

    refute Map.has_key?(usage, :output_tokens)
  end

  test "Codex recognizes an atom-keyed elicitation notification" do
    assert %{blocker: {:input_required, "codex MCP elicitation requires operator input"}} =
             CodexRuntime.normalize_update(%{
               event: :notification,
               timestamp: DateTime.utc_now(),
               payload: %{method: "mcpServer/elicitation/request"}
             })
  end

  test "Codex prefers an explicit rate-limit snapshot to one in the payload" do
    limits = %{"limit_id" => "explicit", "primary" => %{"used_percent" => 10}}

    assert %{rate_limits: ^limits} =
             CodexRuntime.normalize_update(%{
               event: :notification,
               timestamp: DateTime.utc_now(),
               rate_limits: limits,
               payload: %{"rate_limits" => %{"limit_id" => "nested", "primary" => %{"used_percent" => 50}}}
             })
  end

  test "a scheduled runtime can block an issue for approval" do
    {issue, server, workspace_root} = schedule_issue()

    assert_receive {:test_turn_started, worker, session, "You are an agent for this repository.", issue_id}, 1_000
    assert issue_id == issue.id
    assert session.workspace == Path.join(workspace_root, issue.identifier)
    assert File.dir?(session.workspace)
    assert %{running: [%{session_id: nil, turn_count: 1}]} = Orchestrator.snapshot(server, 1_000)
    resource_ref = Process.monitor(session.resource)

    send(worker, :require_approval)

    assert_receive {:DOWN, ^resource_ref, :process, _, :normal}, 1_000

    assert %{running: [], retrying: [], blocked: [%{error: "test runtime requires approval"}]} =
             await_snapshot(server, &(&1.blocked != []))
  end

  test "a terminal tracker state stops the runtime and removes its workspace" do
    {issue, server, _workspace_root} = schedule_issue()
    assert_receive {:test_turn_started, worker, session, _prompt, _issue_id}, 1_000
    worker_ref = Process.monitor(worker)
    resource_ref = Process.monitor(session.resource)

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [%{issue | state: "Done"}])
    assert %{queued: true} = Orchestrator.request_refresh(server)

    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _}, 1_000
    assert_receive {:DOWN, ^resource_ref, :process, _, _}, 1_000
    assert %{running: [], retrying: [], blocked: []} = Orchestrator.snapshot(server, 1_000)
    refute File.exists?(session.workspace)
  end

  defp schedule_issue do
    Process.register(self(), __MODULE__)
    :ok = :sys.suspend(Orchestrator)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_issues)
      :ok = :sys.resume(Orchestrator)
    end)

    workspace_root = Path.join(Path.dirname(Workflow.workflow_file_path()), "workspaces")
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", workspace_root: workspace_root)

    issue = %Issue{
      id: "test-runtime-issue",
      identifier: "MT-RUNTIME",
      title: "Run the test runtime",
      state: "In Progress",
      dispatchable: true
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    start_supervised!({Task.Supervisor, name: Module.concat(__MODULE__, TaskSupervisor)})
    server = Module.concat(__MODULE__, Orchestrator)

    start_supervised!({Orchestrator, name: server, task_supervisor: Module.concat(__MODULE__, TaskSupervisor), runtime: TestRuntime})

    {issue, server, workspace_root}
  end

  defp run_completed_codex_turn(status) do
    run_codex_turn(%{"method" => "turn/completed", "params" => %{"turn" => %{"id" => "turn", "status" => status}}})
  end

  defp run_codex_turn(notification) do
    workflow = Workflow.workflow_file_path()
    test_root = Path.dirname(workflow)
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MT-RUNTIME")
    script = Path.join(test_root, "codex")
    File.mkdir_p!(workspace)

    File.write!(script, """
    count=0
    while IFS= read -r _line; do
      count=$((count + 1))
      case "$count" in
        1) printf '%s\n' '{"id":1,"result":{}}' ;;
        3) printf '%s\n' '{"id":2,"result":{"thread":{"id":"thread"}}}' ;;
        4)
          printf '%s\n' '{"id":3,"result":{"turn":{"id":"turn"}}}'
          printf '%s\n' '#{Jason.encode!(notification)}'
          ;;
      esac
    done
    """)

    write_workflow_file!(workflow, workspace_root: workspace_root, codex_command: "sh '#{script}'")

    {:ok, session} = CodexRuntime.start_session(workspace, worker_host: nil)
    issue = %Issue{id: "test-runtime-issue", identifier: "MT-RUNTIME", title: "Run Codex"}

    try do
      result =
        CodexRuntime.run_turn(session, "Run a turn", issue,
          on_message: fn update ->
            send(self(), {:runtime_event, update.event})
            :ok
          end
        )

      {result, drain_runtime_events()}
    after
      CodexRuntime.stop_session(session)
    end
  end

  defp drain_runtime_events do
    receive do
      {:runtime_event, event} -> [event | drain_runtime_events()]
    after
      0 -> []
    end
  end

  defp await_snapshot(server, ready?, remaining \\ 100) do
    snapshot = Orchestrator.snapshot(server, 1_000)

    if ready?.(snapshot) or remaining == 0 do
      snapshot
    else
      Process.sleep(10)
      await_snapshot(server, ready?, remaining - 1)
    end
  end
end
