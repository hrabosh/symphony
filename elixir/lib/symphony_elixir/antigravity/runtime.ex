defmodule SymphonyElixir.Antigravity.Runtime do
  @moduledoc "Runs Google Antigravity using its ACP stdio server."

  @behaviour SymphonyElixir.AgentRuntime

  alias SymphonyElixir.{ACP.Runtime, Config}

  @auth_hint "Antigravity authentication required. Run agy acp --login on the worker or configure Gemini credentials."

  @impl true
  def start_session(workspace, worker_host: nil) do
    Runtime.start_session(workspace, Config.settings!().antigravity, @auth_hint)
  end

  def start_session(_workspace, worker_host: _host), do: {:error, :antigravity_requires_local_worker}

  @impl true
  defdelegate run_turn(session, prompt, issue, opts), to: Runtime

  @impl true
  defdelegate stop_session(session), to: Runtime

  @impl true
  defdelegate request_cancel(pid), to: Runtime

  @impl true
  def handles_timeouts?, do: true
end
