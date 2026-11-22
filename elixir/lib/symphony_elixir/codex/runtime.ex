defmodule SymphonyElixir.Codex.Runtime do
  @moduledoc """
  Adapts Codex App Server sessions and notifications to the agent runtime contract.
  """

  @behaviour SymphonyElixir.AgentRuntime

  alias SymphonyElixir.AgentRuntime
  alias SymphonyElixir.Codex.AppServer

  @impl true
  defdelegate start_session(workspace, opts), to: AppServer

  @impl true
  def run_turn(session, prompt, issue, opts) do
    on_message = Keyword.fetch!(opts, :on_message)

    case AppServer.run_turn(session, prompt, issue, on_message: &on_message.(normalize_update(&1))) do
      {:ok, %{session_id: session_id}} ->
        {:ok, %{session_id: session_id}}

      {:error, {:turn_input_required, _payload}} ->
        {:blocked, blocker(:turn_input_required, nil)}

      {:error, {:approval_required, _payload}} ->
        {:blocked, blocker(:approval_required, nil)}

      {:error, {:turn_cancelled, _params} = reason} ->
        {:cancelled, reason}

      {:error, _reason} = error ->
        error
    end
  end

  @impl true
  defdelegate stop_session(session), to: AppServer

  @doc "Converts an App Server notification to a worker update."
  @spec normalize_update(map()) :: AgentRuntime.update()
  def normalize_update(%{event: event, timestamp: timestamp} = update) do
    message = update[:payload] || update[:raw]
    usage = extract_token_usage(update)

    %{
      event: event,
      timestamp: timestamp,
      message: message,
      session_id: update[:session_id],
      process_id: process_id(update[:codex_app_server_pid]),
      usage:
        %{
          input_tokens: get_token_usage(usage, :input),
          output_tokens: get_token_usage(usage, :output),
          total_tokens: get_token_usage(usage, :total)
        }
        |> Map.reject(fn {_key, value} -> is_nil(value) end),
      rate_limits: extract_rate_limits(update),
      blocker: blocker(event, message)
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp blocker(:turn_input_required, _message), do: {:input_required, "codex turn requires operator input"}
  defp blocker(:approval_required, _message), do: {:approval_required, "codex turn requires approval"}

  defp blocker(_event, %{"method" => "mcpServer/elicitation/request"}),
    do: {:input_required, "codex MCP elicitation requires operator input"}

  defp blocker(_event, %{method: "mcpServer/elicitation/request"}),
    do: {:input_required, "codex MCP elicitation requires operator input"}

  defp blocker(_event, _message), do: nil

  defp process_id(pid) when is_binary(pid), do: pid
  defp process_id(pid) when is_integer(pid) or is_list(pid), do: to_string(pid)
  defp process_id(_pid), do: nil

  defp extract_token_usage(update) do
    payloads = [
      update[:usage],
      Map.get(update, "usage"),
      update[:payload],
      Map.get(update, "payload"),
      update
    ]

    Enum.find_value(payloads, &absolute_token_usage_from_payload/1) ||
      Enum.find_value(payloads, &turn_completed_usage_from_payload/1) ||
      %{}
  end

  defp extract_rate_limits(update) do
    rate_limits_from_payload(update[:rate_limits]) ||
      rate_limits_from_payload(Map.get(update, "rate_limits")) ||
      rate_limits_from_payload(update[:payload]) ||
      rate_limits_from_payload(Map.get(update, "payload")) ||
      rate_limits_from_payload(update)
  end

  defp absolute_token_usage_from_payload(payload) when is_map(payload) do
    absolute_paths = [
      ["params", "msg", "payload", "info", "total_token_usage"],
      [:params, :msg, :payload, :info, :total_token_usage],
      ["params", "msg", "info", "total_token_usage"],
      [:params, :msg, :info, :total_token_usage],
      ["params", "tokenUsage", "total"],
      [:params, :tokenUsage, :total],
      ["tokenUsage", "total"],
      [:tokenUsage, :total]
    ]

    explicit_map_at_paths(payload, absolute_paths)
  end

  defp absolute_token_usage_from_payload(_payload), do: nil

  defp turn_completed_usage_from_payload(payload) when is_map(payload) do
    method = Map.get(payload, "method") || Map.get(payload, :method)

    if method in ["turn/completed", :turn_completed] do
      direct =
        Map.get(payload, "usage") ||
          Map.get(payload, :usage) ||
          map_at_path(payload, ["params", "usage"]) ||
          map_at_path(payload, [:params, :usage])

      if is_map(direct) and integer_token_map?(direct), do: direct
    end
  end

  defp turn_completed_usage_from_payload(_payload), do: nil

  defp rate_limits_from_payload(payload) when is_map(payload) do
    direct = Map.get(payload, "rate_limits") || Map.get(payload, :rate_limits)

    cond do
      rate_limits_map?(direct) ->
        direct

      rate_limits_map?(payload) ->
        payload

      true ->
        payload |> Map.values() |> Enum.find_value(&rate_limits_from_payload/1)
    end
  end

  defp rate_limits_from_payload(payload) when is_list(payload) do
    Enum.find_value(payload, &rate_limits_from_payload/1)
  end

  defp rate_limits_from_payload(_payload), do: nil

  defp rate_limits_map?(payload) when is_map(payload) do
    limit_id =
      Map.get(payload, "limit_id") ||
        Map.get(payload, :limit_id) ||
        Map.get(payload, "limit_name") ||
        Map.get(payload, :limit_name)

    has_buckets =
      Enum.any?(
        ["primary", :primary, "secondary", :secondary, "credits", :credits],
        &Map.has_key?(payload, &1)
      )

    !is_nil(limit_id) and has_buckets
  end

  defp rate_limits_map?(_payload), do: false

  defp explicit_map_at_paths(payload, paths) do
    Enum.find_value(paths, fn path ->
      value = map_at_path(payload, path)

      if is_map(value) and integer_token_map?(value), do: value
    end)
  end

  defp map_at_path(payload, path) do
    Enum.reduce_while(path, payload, fn key, acc ->
      if is_map(acc) and Map.has_key?(acc, key) do
        {:cont, Map.get(acc, key)}
      else
        {:halt, nil}
      end
    end)
  end

  defp integer_token_map?(payload) do
    token_fields = [
      :input_tokens,
      :output_tokens,
      :total_tokens,
      :prompt_tokens,
      :completion_tokens,
      :inputTokens,
      :outputTokens,
      :totalTokens,
      :promptTokens,
      :completionTokens,
      "input_tokens",
      "output_tokens",
      "total_tokens",
      "prompt_tokens",
      "completion_tokens",
      "inputTokens",
      "outputTokens",
      "totalTokens",
      "promptTokens",
      "completionTokens"
    ]

    token_fields
    |> Enum.any?(fn field ->
      value = payload_get(payload, field)
      !is_nil(integer_like(value))
    end)
  end

  defp get_token_usage(usage, :input),
    do:
      payload_get(usage, [
        "input_tokens",
        "prompt_tokens",
        :input_tokens,
        :prompt_tokens,
        :input,
        "promptTokens",
        :promptTokens,
        "inputTokens",
        :inputTokens
      ])

  defp get_token_usage(usage, :output),
    do:
      payload_get(usage, [
        "output_tokens",
        "completion_tokens",
        :output_tokens,
        :completion_tokens,
        :output,
        :completion,
        "outputTokens",
        :outputTokens,
        "completionTokens",
        :completionTokens
      ])

  defp get_token_usage(usage, :total),
    do:
      payload_get(usage, [
        "total_tokens",
        "total",
        :total_tokens,
        :total,
        "totalTokens",
        :totalTokens
      ])

  defp payload_get(payload, fields) when is_list(fields) do
    Enum.find_value(fields, fn field -> map_integer_value(payload, field) end)
  end

  defp payload_get(payload, field), do: map_integer_value(payload, field)

  defp map_integer_value(payload, field) do
    if is_map(payload) do
      value = Map.get(payload, field)
      integer_like(value)
    else
      nil
    end
  end

  defp integer_like(value) when is_integer(value) and value >= 0, do: value

  defp integer_like(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {num, _} when num >= 0 -> num
      _ -> nil
    end
  end

  defp integer_like(_value), do: nil
end
