defmodule SymphonyElixir.WorkflowCheckTest do
  use SymphonyElixir.TestSupport

  @tag :tmp_dir
  test "checks a workflow without starting Symphony or running hooks", %{tmp_dir: dir} do
    workflow = Path.join(dir, "WORKFLOW.md")
    marker = Path.join(dir, "started")
    executable = executable!(dir, "agy", "touch '#{marker}'")
    current_workflow = Workflow.workflow_file_path()

    write_config!(workflow, """
    agent:
      runtime: antigravity
    antigravity:
      command: #{Jason.encode!(executable)}
    hooks:
      after_create: touch '#{marker}'
    """)

    assert {:checked, message} = CLI.evaluate(["check", workflow], %{})
    assert message =~ "antigravity"
    assert message =~ "authentication unverified"
    assert Workflow.workflow_file_path() == current_workflow
    refute File.exists?(marker)
  end

  @tag :tmp_dir
  test "reports invalid YAML without exposing its contents", %{tmp_dir: dir} do
    workflow = Path.join(dir, "WORKFLOW.md")
    write_config!(workflow, "unknown: [private-token-value")

    assert {:error, message} = CLI.evaluate(["check", workflow], %{})
    assert message =~ "invalid YAML"
    refute message =~ "private-token-value"
  end

  @tag :tmp_dir
  test "filters configuration exceptions from a compound YAML key", %{tmp_dir: dir} do
    workflow = Path.join(dir, "WORKFLOW.md")
    write_config!(workflow, "? {secret: private-token-value}\n: invalid")

    assert {:error, message} = CLI.evaluate(["check", workflow], %{})
    refute message =~ "private-token-value"
  end

  @tag :tmp_dir
  test "reports unmatched quoting in the Codex command without echoing it", %{tmp_dir: dir} do
    workflow = Path.join(dir, "WORKFLOW.md")
    command = "codex 'private-token-value"
    write_config!(workflow, "codex:\n  command: #{Jason.encode!(command)}")

    assert {:error, message} = CLI.evaluate(["check", workflow], %{})
    assert message =~ "codex.command"
    refute message =~ "private-token-value"
  end

  @tag :tmp_dir
  test "rejects a named pipe without trying to read it", %{tmp_dir: dir} do
    pipe = Path.join(dir, "WORKFLOW.md")
    assert {"", 0} = System.cmd("mkfifo", [pipe])
    assert {:error, message} = CLI.evaluate(["check", pipe], %{})
    assert message =~ "regular file"
  end

  @tag :tmp_dir
  test "reports the setting for an unknown agent runtime", %{tmp_dir: dir} do
    workflow = Path.join(dir, "WORKFLOW.md")
    write_config!(workflow, "agent:\n  runtime: unknown")

    assert {:error, message} = CLI.evaluate(["check", workflow], %{})
    assert message =~ "agent.runtime"
  end

  @tag :tmp_dir
  test "reports a missing configured executable", %{tmp_dir: dir} do
    workflow = Path.join(dir, "WORKFLOW.md")

    write_config!(workflow, """
    agent:
      runtime: claude_code
    claude_code:
      command: #{Jason.encode!(Path.join(dir, "missing-adapter"))}
    """)

    assert {:error, message} = CLI.evaluate(["check", workflow], %{})
    assert message =~ "claude_code.command"
    assert message =~ "was not found on the worker"
  end

  @tag :tmp_dir
  test "reports missing Claude authentication without exposing the probe output", %{tmp_dir: dir} do
    executable =
      executable!(dir, "claude-agent-acp", """
      test "$*" = '--cli auth status --json' || exit 2
      printf '%s\n' '{"loggedIn":false,"credential":"private-token-value"}'
      exit 1
      """)

    workflow = Path.join(dir, "WORKFLOW.md")

    write_config!(workflow, """
    agent:
      runtime: claude_code
    claude_code:
      command: #{Jason.encode!(executable)}
    """)

    assert {:error, message} = CLI.evaluate(["check", workflow], %{})
    assert message =~ "Claude Code"
    assert message =~ "auth login"
    refute message =~ "private-token-value"
  end

  @tag :tmp_dir
  test "recognizes Codex login status without executing its launch command", %{tmp_dir: dir} do
    executable =
      executable!(dir, "codex", """
      test "$*" = 'login status' || exit 2
      printf '%s\n' 'Logged in using an API key private-token-value' >&2
      """)

    workflow = Path.join(dir, "WORKFLOW.md")
    write_config!(workflow, "codex:\n  command: #{Jason.encode!(executable <> " app-server")}")

    assert {:checked, message} = CLI.evaluate(["check", workflow], %{})
    assert message =~ "Codex authentication verified"
    refute message =~ "private-token-value"
  end

  @tag :tmp_dir
  test "does not pass the requested workflow's tracker credential to the auth subprocess", %{tmp_dir: dir} do
    env_name = "SYMPHONY_TEST_CHECK_TRACKER_TOKEN"
    previous = System.get_env(env_name)
    on_exit(fn -> restore_env(env_name, previous) end)
    System.put_env(env_name, "private-token-value")

    executable =
      executable!(dir, "codex", """
      test -z "$SYMPHONY_TEST_CHECK_TRACKER_TOKEN" || exit 2
      printf '%s\n' 'Logged in'
      """)

    workflow = Path.join(dir, "WORKFLOW.md")

    File.write!(workflow, """
    ---
    tracker:
      kind: linear
      provider:
        project_slug: check-fixture
        api_key: $SYMPHONY_TEST_CHECK_TRACKER_TOKEN
    codex:
      command: #{Jason.encode!("\"#{executable}\" app-server")}
    ---
    """)

    assert {:checked, message} = CLI.evaluate(["check", workflow], %{})
    assert message =~ "authentication verified"
    refute message =~ "private-token-value"
  end

  @tag :tmp_dir
  test "marks shell-dependent executable and authentication checks unverified", %{tmp_dir: dir} do
    workflow = Path.join(dir, "WORKFLOW.md")
    marker = Path.join(dir, "started")
    write_config!(workflow, "codex:\n  command: '$CODEX_BIN app-server; touch #{marker}'")

    assert {:checked, message} = CLI.evaluate(["check", workflow], %{})
    assert message =~ "codex.command executable unverified"
    refute File.exists?(marker)
  end

  @tag :tmp_dir
  test "reports a rejected Codex credential without disclosing the probe output", %{tmp_dir: dir} do
    executable =
      executable!(dir, "codex", """
      printf '%s\n' 'Error: Invalid API key private-token-value' >&2
      exit 1
      """)

    workflow = Path.join(dir, "WORKFLOW.md")
    write_config!(workflow, "codex:\n  command: #{Jason.encode!(executable <> " app-server")}")

    assert {:error, message} = CLI.evaluate(["check", workflow], %{})
    assert message =~ "Codex authentication rejected"
    refute message =~ "private-token-value"
  end

  @tag :tmp_dir
  test "checks configured SSH workers instead of requiring Codex locally", %{tmp_dir: dir} do
    executable!(dir, "ssh", """
    case "$*" in
      *BatchMode=yes*StrictHostKeyChecking=yes*worker.example*'command -v'*codex*) exit 0 ;;
      *) exit 2 ;;
    esac
    """)

    workflow = Path.join(dir, "WORKFLOW.md")

    write_config!(workflow, """
    worker:
      ssh_hosts: [worker.example]
    """)

    assert {:checked, message} = CLI.evaluate(["check", workflow], %{})
    assert message =~ "all SSH workers"
    assert message =~ "authentication unverified"
  end

  @tag :tmp_dir
  test "rejects an SSH target starting with an option before invoking SSH", %{tmp_dir: dir} do
    marker = Path.join(dir, "ssh-called")
    executable!(dir, "ssh", "touch '#{marker}'")
    workflow = Path.join(dir, "WORKFLOW.md")
    write_config!(workflow, "worker:\n  ssh_hosts: ['-oProxyCommand=unexpected']")

    assert {:error, message} = CLI.evaluate(["check", workflow], %{})
    assert message =~ "worker.ssh_hosts"
    refute File.exists?(marker)
  end

  defp write_config!(workflow, settings) do
    File.write!(workflow, "---\ntracker:\n  kind: memory\n#{String.trim(settings)}\n---\nFixture")
  end

  defp executable!(dir, name, script) do
    previous_path = System.get_env("PATH")
    System.put_env("PATH", dir <> ":" <> (previous_path || ""))
    on_exit(fn -> restore_env("PATH", previous_path) end)

    path = Path.join(dir, name)
    File.write!(path, "#!/bin/sh\n" <> script <> "\n")
    File.chmod!(path, 0o755)
    path
  end
end
