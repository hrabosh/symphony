defmodule SymphonyElixir.ClaudeCode.Runtime do
  @moduledoc "Runs the Claude Agent SDK using the Claude ACP adapter."

  @behaviour SymphonyElixir.AgentRuntime

  alias SymphonyElixir.{ACP.Runtime, Config}

  @auth_hint "Claude Code authentication required. Run claude-agent-acp --cli auth login on the worker or configure Anthropic credentials."

  @impl true
  def start_session(workspace, worker_host: nil) do
    Runtime.start_session(workspace, Config.settings!().claude_code, @auth_hint)
  end

  def start_session(_workspace, worker_host: _host), do: {:error, :claude_code_requires_local_worker}

  @impl true
  defdelegate run_turn(session, prompt, issue, opts), to: Runtime

  @impl true
  defdelegate stop_session(session), to: Runtime

  @impl true
  defdelegate request_cancel(pid), to: Runtime

  @impl true
  def handles_timeouts?, do: true
end
