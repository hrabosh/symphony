defmodule SymphonyElixir.AgentRuntimeLiveSmokeTest do
  use SymphonyElixir.TestSupport

  @moduletag :live_e2e

  unless System.get_env("SYMPHONY_RUN_AGENT_RUNTIME_SMOKE") == "1" do
    @moduletag skip: "set SYMPHONY_RUN_AGENT_RUNTIME_SMOKE=1 to run live agent comparisons"
  end

  for runtime <- ["codex", "antigravity", "claude_code"] do
    @tag timeout: 180_000
    test "#{runtime} delivers a tested change for the same local Git fixture" do
      run_fixture(unquote(runtime))
    end
  end

  defp run_fixture(runtime) do
    test_root = Path.dirname(Workflow.workflow_file_path())
    repository = Path.join(test_root, "repository")
    root = Path.join(test_root, "workspaces")
    File.mkdir_p!(repository)

    File.write!(Path.join(repository, "fixture.txt"), "pending\n")
    File.write!(Path.join(repository, "verify.sh"), ~S|test "$(cat fixture.txt)" = "ready"| <> "\n")
    git!(repository, ["init", "--quiet"])
    git!(repository, ["add", "."])
    git!(repository, ["-c", "user.name=Symphony Smoke", "-c", "user.email=smoke@example.test", "commit", "-qm", "Fixture"])

    suspend_default_scheduler()
    configure_fixture(runtime, root, repository)

    issue = %Issue{
      id: "fixture-1",
      identifier: "SMOKE-1",
      title: "Make the fixture ready",
      state: "In Progress",
      dispatchable: true
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    task_supervisor = Module.concat(__MODULE__, TaskSupervisor)
    server = Module.concat(__MODULE__, Orchestrator)
    start_supervised!({Task.Supervisor, name: task_supervisor})
    start_supervised!({Orchestrator, name: server, task_supervisor: task_supervisor})
    await_fixture(server, System.monotonic_time(:millisecond) + 150_000)
    Application.delete_env(:symphony_elixir, :memory_tracker_issues)

    workspace = Path.join(root, issue.identifier)
    assert {"", 0} = System.cmd("sh", ["verify.sh"], cd: workspace)
    diff = git!(workspace, ["diff", "HEAD", "--", "fixture.txt"])
    assert diff =~ "-pending\n+ready"
    assert git!(workspace, ["diff", "HEAD", "--", "verify.sh"]) == ""
  end

  defp configure_fixture(runtime, root, repository) do
    File.write!(Workflow.workflow_file_path(), """
    ---
    tracker:
      kind: memory
    workspace:
      root: #{Jason.encode!(root)}
    hooks:
      after_create: |
        git clone --quiet '#{repository}' .
    agent:
      runtime: #{runtime}
      max_turns: 1
      max_retry_backoff_ms: 300000
    antigravity:
      approval_policy: allow_once
      read_timeout_ms: 15000
      turn_timeout_ms: 120000
    claude_code:
      command: #{Jason.encode!(System.get_env("SYMPHONY_CLAUDE_ACP_BIN", "claude-agent-acp"))}
      approval_policy: allow_once
      read_timeout_ms: 15000
      turn_timeout_ms: 120000
    codex:
      approval_policy: on-request
      read_timeout_ms: 15000
      turn_timeout_ms: 120000
    ---
    In the current Git repository, change exactly fixture.txt to contain ready followed by a newline.
    Run sh verify.sh. Leave the change in the workspace for review.
    """)

    assert :ok = WorkflowStore.force_reload()
  end

  defp suspend_default_scheduler do
    :ok = :sys.suspend(Orchestrator)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_issues)
      :ok = :sys.resume(Orchestrator)
    end)
  end

  defp await_fixture(server, deadline) do
    case Orchestrator.snapshot(server, 1_000) do
      %{blocked: [%{error: reason} | _]} ->
        flunk("Agent blocked: #{reason}")

      %{retrying: [%{error: nil} | _]} ->
        :ok

      %{retrying: [%{error: reason} | _]} ->
        flunk("Agent failed: #{reason}")

      _ ->
        assert System.monotonic_time(:millisecond) < deadline, "Agent smoke test timed out"
        Process.sleep(100)
        await_fixture(server, deadline)
    end
  end

  defp git!(workspace, args) do
    {output, status} = System.cmd("git", args, cd: workspace, stderr_to_stdout: true)
    assert status == 0, output
    output
  end
end
