defmodule SymphonyElixir.ACPClientTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Antigravity.Runtime
  alias SymphonyElixir.Config.Schema

  test "selects and validates Antigravity in a workflow" do
    assert {:ok, %{agent: %{runtime: "antigravity"}}} = Schema.parse(%{"agent" => %{"runtime" => "antigravity"}})
    assert {:error, {:invalid_workflow_config, message}} = Schema.parse(%{"antigravity" => %{"approval_policy" => "typo"}})
    assert message =~ "antigravity.approval_policy"
  end

  test "runs multiple turns in the assigned workspace and forwards progress" do
    assert {:ok, session} = open_stub("complete")

    try do
      assert {:ok, %{session_id: "stub-session"}} = prompt(session)
      assert_receive {:runtime_update, %{event: :turn_started, session_id: "stub-session"}}
      assert_receive {:runtime_update, %{message: "Working"}}
      assert {:ok, %{session_id: "stub-session"}} = prompt(session)
    after
      Runtime.stop_session(session)
    end
  end

  test "blocks a missing Antigravity login with a setup hint" do
    assert {:blocked, {:input_required, message}} = open_stub("auth")
    assert message =~ "agy acp --login"
  end

  test "blocks a permission request by default and cancels the turn" do
    marker = Path.join(Path.dirname(Workflow.workflow_file_path()), "cancelled")
    assert {:ok, session} = open_stub("permission", [marker])

    try do
      assert {:blocked, {:approval_required, _}} = prompt(session)
      assert File.read!(marker) == "cancelled"
    after
      Runtime.stop_session(session)
    end
  end

  test "explicit approval policy selects the one-time option" do
    assert {:ok, session} = open_stub("permission", [], "allow_once")

    try do
      assert {:ok, %{session_id: "stub-session"}} = prompt(session)
    after
      Runtime.stop_session(session)
    end
  end

  test "an unanswered input request blocks the run" do
    marker = Path.join(Path.dirname(Workflow.workflow_file_path()), "cancelled")
    assert {:ok, session} = open_stub("input", [marker])

    try do
      assert {:blocked, {:input_required, _}} = prompt(session)
      assert File.read!(marker) == "cancelled"
    after
      Runtime.stop_session(session)
    end
  end

  test "Antigravity rejects the workspace root, unreadable paths, and SSH workers" do
    workflow_root = Path.dirname(Workflow.workflow_file_path())
    root = Path.join(workflow_root, "workspaces")
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: root)
    assert {:error, :invalid_acp_workspace} = Runtime.start_session(root, worker_host: nil)
    assert {:error, :antigravity_requires_local_worker} = Runtime.start_session(root, worker_host: "ssh-host")

    File.mkdir_p!(root)
    file = Path.join(root, "file")
    File.write!(file, "")
    invalid_path = Path.join(file, "child")

    assert {:error, {:path_canonicalize_failed, ^invalid_path, :enotdir}} =
             Runtime.start_session(invalid_path, worker_host: nil)
  end

  test "reports a broken agent process" do
    assert {:ok, session} = open_stub("crash")

    try do
      assert {:error, {:acp_process_exit, 7}} = prompt(session)
    after
      Runtime.stop_session(session)
    end
  end

  test "cancellation also answers a permission request with the same RPC ID" do
    marker = Path.join(Path.dirname(Workflow.workflow_file_path()), "cancelled")
    parent = self()

    task =
      Task.async(fn ->
        {:ok, session} = open_stub("cancel-collision", [marker])
        send(parent, :session_ready)

        try do
          prompt(session, parent)
        after
          Runtime.stop_session(session)
        end
      end)

    assert_receive :session_ready, 2_000
    assert_receive {:runtime_update, %{message: "Working"}}, 2_000
    assert :ok = Runtime.request_cancel(task.pid)
    assert {:cancelled, _} = Task.await(task)
    assert File.read!(marker) == "cancelled"
  end

  test "tracker cancellation stops the ACP turn before removing its workspace" do
    marker = Path.join(Path.dirname(Workflow.workflow_file_path()), "tracker-cancelled")
    {server, issue, workspace} = schedule_stub("wait", [marker])
    assert %{running: [%{session_id: "stub-session"}]} = await_snapshot(server, :running)

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [%{issue | state: "Done"}])
    assert %{queued: true} = Orchestrator.request_refresh(server)

    for _ <- 1..100, not File.exists?(marker), do: Process.sleep(10)
    assert File.read!(marker) == "cancelled"
    assert %{running: [], blocked: [], retrying: []} = Orchestrator.snapshot(server, 1_000)
    refute File.exists?(workspace)
  end

  test "the scheduler exposes missing authentication as blocked" do
    {server, _issue, _workspace} = schedule_stub("auth", [])
    assert %{running: [], retrying: [], blocked: [%{error: error}]} = await_snapshot(server, :blocked)
    assert error =~ "agy acp --login"
  end

  test "a broken ACP process enters the scheduler's retry queue" do
    {server, _issue, _workspace} = schedule_stub("crash", [])
    assert %{running: [], blocked: [], retrying: [%{error: error}]} = await_snapshot(server, :retrying)
    assert error =~ "{:acp_process_exit, 7}"
  end

  test "Claude Code uses the shared ACP policy and exposes the provider for blocked runs" do
    assert {:ok, %{claude_code: %{command: "claude-agent-acp", args: [], approval_policy: "block"}}} =
             Schema.parse(%{"agent" => %{"runtime" => "claude_code"}})

    {server, _issue, _workspace} = schedule_stub("permission", [], "claude_code")

    assert %{blocked: [%{agent_runtime: "claude_code", error: "ACP agent requires approval"}]} =
             await_snapshot(server, :blocked)

    assert %{blocked: [%{agent_runtime: "claude_code"}]} =
             SymphonyElixirWeb.Presenter.state_payload(server, 1_000)
  end

  test "Claude Code requires a usable executable and a local worker" do
    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{"claude_code" => %{"command" => " "}})

    assert message =~ "claude_code.command"

    assert {:error, :claude_code_requires_local_worker} =
             SymphonyElixir.ClaudeCode.Runtime.start_session("/unused", worker_host: "ssh-host")
  end

  test "Claude Code startup reports its own authentication hint" do
    {server, _issue, _workspace} = schedule_stub("auth", [], "claude_code")

    assert %{retrying: [], blocked: [%{agent_runtime: "claude_code", error: error}]} =
             await_snapshot(server, :blocked)

    assert error =~ "claude-agent-acp --cli auth login"
  end

  test "Claude Code remains visible in the retry API after a failed attempt" do
    {server, issue, _workspace} = schedule_stub("crash", [], "claude_code")
    assert %{retrying: [%{agent_runtime: "claude_code"}]} = await_snapshot(server, :retrying)

    assert {:ok, %{retry: %{agent_runtime: "claude_code"}}} =
             SymphonyElixirWeb.Presenter.issue_payload(issue.identifier, server, 1_000)
  end

  test "tracker cancellation reaches the Claude Code ACP session" do
    marker = Path.join(Path.dirname(Workflow.workflow_file_path()), "claude-cancelled")
    {server, issue, workspace} = schedule_stub("wait", [marker], "claude_code")
    assert %{running: [%{agent_runtime: "claude_code"}]} = await_snapshot(server, :running)

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [%{issue | state: "Done"}])
    assert %{queued: true} = Orchestrator.request_refresh(server)

    for _ <- 1..100, not File.exists?(marker), do: Process.sleep(10)
    assert File.read!(marker) == "cancelled"
    assert %{running: [], blocked: [], retrying: []} = Orchestrator.snapshot(server, 1_000)
    refute File.exists?(workspace)
  end

  defp open_stub(mode, args \\ [], policy \\ "block") do
    workspace = configure_stub(mode, args, policy)
    Runtime.start_session(workspace, worker_host: nil)
  end

  defp schedule_stub(mode, args, runtime \\ "antigravity") do
    :ok = :sys.suspend(Orchestrator)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_issues)
      :ok = :sys.resume(Orchestrator)
    end)

    workspace = configure_stub(mode, args, "block", runtime)
    issue = %Issue{id: "fixture", identifier: "MT-ACP", title: "Run the fixture", state: "Todo", dispatchable: true}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    task_supervisor = Module.concat(__MODULE__, TaskSupervisor)
    server = Module.concat(__MODULE__, Orchestrator)
    start_supervised!({Task.Supervisor, name: task_supervisor})
    start_supervised!({Orchestrator, name: server, task_supervisor: task_supervisor})
    {server, issue, workspace}
  end

  defp await_snapshot(server, field, attempts \\ 100) do
    snapshot = Orchestrator.snapshot(server, 1_000)

    case {field, snapshot} do
      {:running, %{running: [%{session_id: "stub-session"}]}} ->
        snapshot

      {:blocked, %{blocked: [_ | _]}} ->
        snapshot

      {:retrying, %{retrying: [_ | _]}} ->
        snapshot

      _ when attempts == 0 ->
        snapshot

      _ ->
        Process.sleep(10)
        await_snapshot(server, field, attempts - 1)
    end
  end

  defp configure_stub(mode, args, policy, runtime \\ "antigravity") do
    workflow = Workflow.workflow_file_path()
    root = Path.join(Path.dirname(workflow), "workspaces")
    workspace = Path.join(root, "MT-ACP")
    File.mkdir_p!(workspace)
    fixture = Path.expand("../fixtures/acp_stub.py", __DIR__)

    File.write!(workflow, """
    ---
    tracker:
      kind: memory
    workspace:
      root: #{Jason.encode!(root)}
    agent:
      runtime: #{runtime}
    #{runtime}:
      command: python3
      args: #{Jason.encode!([fixture, mode | args])}
      approval_policy: #{policy}
    ---
    Run the fixture.
    """)

    assert :ok = WorkflowStore.force_reload()
    workspace
  end

  defp prompt(session, recipient \\ self()) do
    Runtime.run_turn(session, "Implement the test ticket.", %Issue{id: "fixture", identifier: "MT-ACP"},
      on_message: fn update ->
        send(recipient, {:runtime_update, update})
        :ok
      end
    )
  end
end
