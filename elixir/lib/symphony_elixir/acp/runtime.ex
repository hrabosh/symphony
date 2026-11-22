defmodule SymphonyElixir.ACP.Runtime do
  @moduledoc "Shared worker lifecycle and workspace checks for local ACP profiles."

  alias SymphonyElixir.{ACP.Client, AgentRuntime, Config, PathSafety, Tracker}

  @spec start_session(Path.t(), struct(), String.t()) :: {:ok, map()} | AgentRuntime.turn_error()
  def start_session(workspace, settings, auth_hint) do
    with {:ok, workspace} <- PathSafety.canonicalize(workspace),
         {:ok, root} <- PathSafety.canonicalize(Config.local_workspace_root()),
         true <- String.starts_with?(workspace, root <> "/") do
      secret_names = Tracker.bind_agent_tools().secret_environment_names
      client_settings = settings |> Map.from_struct() |> Map.put(:auth_hint, auth_hint)
      Client.start(workspace, client_settings, secret_names)
    else
      false -> {:error, :invalid_acp_workspace}
      {:error, _} = error -> error
    end
  end

  @spec run_turn(map(), String.t(), term(), on_message: (AgentRuntime.update() -> :ok)) :: AgentRuntime.turn_result()
  def run_turn(session, prompt, _issue, on_message: on_message), do: Client.prompt(session, prompt, on_message)

  @spec stop_session(map()) :: :ok
  defdelegate stop_session(session), to: Client, as: :stop

  @spec request_cancel(pid()) :: :ok
  def request_cancel(pid) do
    send(pid, :cancel_agent)
    :ok
  end
end
