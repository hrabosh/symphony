defmodule SymphonyElixir.ACP.Client do
  @moduledoc """
  Worker-owned ACP v1 client over newline-delimited JSON-RPC on stdio.
  """

  alias SymphonyElixir.AgentRuntime

  @line_bytes 1_048_576
  @cancel_grace_ms 250

  @spec start(Path.t(), map(), [String.t()]) :: {:ok, map()} | AgentRuntime.turn_error()
  def start(workspace, settings, secret_names) do
    with {:ok, port} <- open_port(workspace, settings, secret_names) do
      session = %{port: port, settings: settings, id: nil}

      case initialize(session, workspace) do
        {:ok, id} ->
          {:ok, %{session | id: id}}

        outcome ->
          stop(session)
          outcome
      end
    end
  end

  @spec prompt(map(), String.t(), (AgentRuntime.update() -> :ok)) :: AgentRuntime.turn_result()
  def prompt(session, prompt, on_message) do
    id = System.unique_integer([:positive, :monotonic]) + 2
    params = %{"sessionId" => session.id, "prompt" => [%{"type" => "text", "text" => prompt}]}
    emit(on_message, session.id, :turn_started, nil)
    wait = %{id: id, on_message: on_message, timeout_ms: session.settings.turn_timeout_ms}

    case request(session, wait, "session/prompt", params) do
      {:ok, %{"stopReason" => "end_turn"}} ->
        emit(on_message, session.id, :turn_completed, "Turn completed")
        {:ok, %{session_id: session.id}}

      {:ok, %{"stopReason" => "cancelled"}} ->
        {:cancelled, :acp_cancelled}

      {:ok, %{"stopReason" => reason}} ->
        {:error, {:acp_stop_reason, reason}}

      {:ok, _result} ->
        {:error, :invalid_acp_prompt_result}

      outcome ->
        outcome
    end
  end

  @spec stop(map()) :: :ok
  def stop(%{port: port}) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp open_port(workspace, settings, secret_names) do
    case System.find_executable(settings.command) do
      nil ->
        {:error, {:acp_executable_not_found, settings.command}}

      executable ->
        port =
          Port.open({:spawn_executable, executable}, [
            :binary,
            :exit_status,
            {:line, @line_bytes},
            {:cd, workspace},
            {:args, settings.args},
            {:env, Enum.map(secret_names, &{String.to_charlist(&1), false})}
          ])

        {:ok, port}
    end
  rescue
    error in [ArgumentError, ErlangError] -> {:error, {:acp_launch_failed, Exception.message(error)}}
  end

  defp initialize(session, workspace) do
    wait = %{id: 1, on_message: nil, timeout_ms: session.settings.read_timeout_ms}

    with {:ok, %{"protocolVersion" => 1}} <-
           request(session, wait, "initialize", %{
             "protocolVersion" => 1,
             "clientCapabilities" => %{"elicitation" => %{"form" => %{}}}
           }),
         {:ok, %{"sessionId" => id}} when is_binary(id) and id != "" <-
           request(session, %{wait | id: 2}, "session/new", %{"cwd" => workspace, "mcpServers" => []}) do
      {:ok, id}
    else
      {:ok, _unexpected} -> {:error, :invalid_acp_handshake}
      outcome -> outcome
    end
  end

  defp request(session, wait, method, params) do
    with :ok <- send_json(session.port, %{id: wait.id, method: method, params: params}) do
      await_response(session, wait, deadline(wait.timeout_ms))
    end
  end

  defp await_response(%{port: port} = session, wait, due_at) do
    remaining = due_at - System.monotonic_time(:millisecond)

    if remaining > 0 do
      receive_response(port, session, wait, due_at, remaining)
    else
      finish_prompt(session, wait.id, {:error, :acp_response_timeout})
    end
  end

  defp receive_response(port, session, wait, due_at, remaining) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        case Jason.decode(line) do
          {:ok, %{"jsonrpc" => "2.0"} = message} -> handle_message(message, session, wait, due_at)
          _ -> {:error, :invalid_acp_message}
        end

      {^port, {:data, {:noeol, _}}} ->
        {:error, :acp_message_too_large}

      {^port, {:exit_status, status}} ->
        {:error, {:acp_process_exit, status}}

      :cancel_agent ->
        finish_prompt(session, wait.id, {:cancelled, :acp_cancelled})
    after
      remaining ->
        finish_prompt(session, wait.id, {:error, :acp_response_timeout})
    end
  end

  defp handle_message(%{"id" => id, "result" => result}, session, %{id: id}, _due_at)
       when session.id != nil or is_map(result),
       do: {:ok, result}

  defp handle_message(%{"id" => id, "error" => %{"code" => -32_000}}, session, %{id: id}, _due_at) do
    {:blocked, {:input_required, session.settings.auth_hint}}
  end

  defp handle_message(%{"id" => id, "error" => error}, _session, %{id: id}, _due_at) do
    {:error, {:acp_error, error["code"], error["message"]}}
  end

  defp handle_message(
         %{"method" => "session/update", "params" => %{"sessionId" => id, "update" => update}},
         %{id: id} = session,
         %{on_message: on_message} = wait,
         _due_at
       )
       when is_binary(id) and is_function(on_message, 1) and is_map(update) do
    emit(on_message, id, :agent_progress, progress_text(update))
    await_response(session, wait, deadline(wait.timeout_ms))
  end

  defp handle_message(
         %{"method" => "session/request_permission", "id" => request_id, "params" => %{"sessionId" => id} = params},
         %{id: id} = session,
         wait,
         due_at
       )
       when is_binary(id) do
    handle_permission(request_id, params["options"], session, wait, due_at)
  end

  defp handle_message(
         %{"method" => "elicitation/create", "id" => request_id, "params" => %{"sessionId" => id}},
         %{id: id} = session,
         wait,
         _due_at
       )
       when is_binary(id) do
    send_json(session.port, %{id: request_id, result: %{action: "cancel"}})
    finish_prompt(session, wait.id, {:blocked, {:input_required, "ACP agent requires operator input"}})
  end

  defp handle_message(%{"method" => _, "id" => request_id}, session, wait, due_at) do
    send_json(session.port, %{id: request_id, error: %{code: -32_601, message: "Method not supported"}})
    await_response(session, wait, due_at)
  end

  defp handle_message(_message, session, wait, due_at), do: await_response(session, wait, due_at)

  defp handle_permission(request_id, options, session, wait, due_at) do
    case one_time_approval(session.settings.approval_policy, options) do
      nil ->
        send_permission(session.port, request_id, %{outcome: "cancelled"})
        finish_prompt(session, wait.id, {:blocked, {:approval_required, "ACP agent requires approval"}})

      option_id ->
        with :ok <- send_permission(session.port, request_id, %{outcome: "selected", optionId: option_id}) do
          await_response(session, wait, due_at)
        end
    end
  end

  defp one_time_approval("allow_once", options) when is_list(options) do
    Enum.find_value(options, fn
      %{"kind" => "allow_once", "optionId" => id} when is_binary(id) -> id
      _ -> nil
    end)
  end

  defp one_time_approval(_policy, _options), do: nil

  defp send_permission(port, id, outcome), do: send_json(port, %{id: id, result: %{outcome: outcome}})

  defp finish_prompt(%{id: id, port: port}, request_id, outcome) when is_binary(id) do
    send_json(port, %{method: "session/cancel", params: %{sessionId: id}})
    await_cancellation(port, request_id, deadline(@cancel_grace_ms))
    outcome
  end

  defp finish_prompt(_session, _request_id, outcome), do: outcome

  defp await_cancellation(port, request_id, due_at) do
    remaining = due_at - System.monotonic_time(:millisecond)

    if remaining > 0 do
      receive do
        {^port, {:data, {:eol, line}}} -> cancellation_response(Jason.decode(line), port, request_id, due_at)
        {^port, {:exit_status, _status}} -> :ok
      after
        remaining -> :ok
      end
    else
      :ok
    end
  end

  defp cancellation_response({:ok, %{"id" => id, "result" => _}}, _port, id, _due_at), do: :ok
  defp cancellation_response({:ok, %{"id" => id, "error" => _}}, _port, id, _due_at), do: :ok

  defp cancellation_response({:ok, %{"method" => "session/request_permission", "id" => id}}, port, request_id, due_at) do
    send_permission(port, id, %{outcome: "cancelled"})
    await_cancellation(port, request_id, due_at)
  end

  defp cancellation_response(_message, port, request_id, due_at), do: await_cancellation(port, request_id, due_at)

  defp progress_text(%{"sessionUpdate" => "agent_message_chunk", "content" => %{"type" => "text", "text" => text}})
       when is_binary(text),
       do: String.slice(text, 0, 140)

  defp progress_text(%{"sessionUpdate" => kind}) when is_binary(kind), do: String.slice(kind, 0, 140)
  defp progress_text(_update), do: "Agent progress"

  defp emit(on_message, id, event, message) do
    on_message.(%{event: event, timestamp: DateTime.utc_now(), session_id: id, message: message})
  end

  defp deadline(timeout_ms), do: System.monotonic_time(:millisecond) + timeout_ms

  defp send_json(port, message) do
    if Port.command(port, [Jason.encode!(Map.put(message, :jsonrpc, "2.0")), "\n"], [:nosuspend]) do
      :ok
    else
      {:error, :acp_process_busy}
    end
  rescue
    ArgumentError -> {:error, :acp_process_closed}
  end
end
