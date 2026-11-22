defmodule SymphonyElixir.AgentRuntime do
  @moduledoc """
  Runs agent sessions owned by a Symphony worker.

  A worker owns its session and its resources for the entire attempt. Runtimes
  must bind those resources to the worker so stopping the worker also stops
  active work, even when there is no opportunity to call `stop_session/1`.
  Progress callbacks run synchronously in the worker to keep their order with
  the worker's exit notification. Report each new turn once as `:turn_started` and
  token usage as cumulative totals for the worker's session. An update can set
  a blocker while waiting for input or approval and clear it with `blocker: nil`.
  """

  alias SymphonyElixir.Tracker.Issue

  @runtimes %{
    "codex" => SymphonyElixir.Codex.Runtime,
    "antigravity" => SymphonyElixir.Antigravity.Runtime,
    "claude_code" => SymphonyElixir.ClaudeCode.Runtime
  }

  @type blocker :: {:input_required | :approval_required, String.t()}
  @type usage :: %{
          optional(:input_tokens) => non_neg_integer(),
          optional(:output_tokens) => non_neg_integer(),
          optional(:total_tokens) => non_neg_integer()
        }
  @type update :: %{
          required(:event) => atom(),
          required(:timestamp) => DateTime.t(),
          optional(:message) => term(),
          optional(:session_id) => String.t(),
          optional(:process_id) => String.t(),
          optional(:usage) => usage(),
          optional(:rate_limits) => map(),
          optional(:blocker) => blocker() | nil
        }
  @type turn_result :: {:ok, %{optional(:session_id) => String.t()}} | turn_error()
  @type turn_error ::
          {:error, term()}
          | {:cancelled, term()}
          | {:blocked, blocker()}

  @callback start_session(Path.t(), worker_host: String.t() | nil) :: {:ok, term()} | turn_error()
  @callback run_turn(term(), String.t(), Issue.t(), on_message: (update() -> :ok)) :: turn_result()
  @callback stop_session(term()) :: :ok
  @callback request_cancel(pid()) :: :ok
  @callback handles_timeouts?() :: boolean()
  @optional_callbacks request_cancel: 1, handles_timeouts?: 0

  @doc "Reports the runtime names accepted in workflow configuration."
  @spec names() :: [String.t()]
  def names, do: Map.keys(@runtimes)

  @doc "Fetches the implementation for a validated runtime name."
  @spec fetch!(String.t()) :: module()
  def fetch!(name), do: Map.fetch!(@runtimes, name)
end
