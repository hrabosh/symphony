defmodule SymphonyElixir.WorkflowCheck do
  @moduledoc "Validates a workflow and checks worker prerequisites without starting Symphony."

  alias SymphonyElixir.{Config, SSH, Tracker}

  @probe_timeout_ms 5_000
  @probe_output_limit 16_384

  @spec run(Path.t()) :: {:checked, String.t()} | {:error, String.t()}
  def run(path) do
    if File.regular?(path) do
      case load_workflow(path) do
        {:ok, _workflow, settings} -> check_runtime(settings)
        {:error, reason} -> {:error, workflow_error(reason)}
      end
    else
      {:error, "Workflow file is missing or is not a regular file."}
    end
  end

  defp load_workflow(path) do
    Config.load_workflow(path)
  rescue
    _error in [ArgumentError, Protocol.UndefinedError] ->
      {:error, {:invalid_workflow_config, "Check the YAML configuration keys and values."}}
  end

  defp check_runtime(%{agent: %{runtime: "codex"}} = settings) do
    case codex_executable(settings.codex.command) do
      :invalid -> {:error, "Invalid codex.command. Check its shell quoting."}
      reference -> check_codex_workers(settings, reference)
    end
  end

  defp check_runtime(%{agent: %{runtime: runtime}} = settings) do
    profile = Map.fetch!(settings, String.to_existing_atom(runtime))
    check_local(runtime, runtime <> ".command", {:known, profile.command}, settings.tracker)
  end

  defp check_codex_workers(%{worker: %{ssh_hosts: [_ | _] = hosts}}, reference) do
    check_remote_workers(hosts, reference)
  end

  defp check_codex_workers(settings, reference) do
    if System.find_executable("bash") do
      check_local("codex", "codex.command", reference, settings.tracker)
    else
      {:error, "Codex requires Bash on the worker. Install bash and rerun the check."}
    end
  end

  defp codex_executable(command) do
    with [executable | args] <- OptionParser.split(command),
         {:known, executable} <- executable_reference(executable) do
      direct_launch? = args == ["app-server"] and not String.contains?(command, ["\n", "\r"])
      {if(direct_launch?, do: :codex_launch, else: :known), executable}
    else
      _ -> :unverified
    end
  rescue
    RuntimeError -> :invalid
  end

  defp executable_reference(executable) do
    cond do
      Path.type(executable) == :absolute and String.valid?(executable) and
          not String.contains?(executable, ["$", "`", "\n", "\r", <<0>>]) ->
        {:known, executable}

      Regex.match?(~r/\A[A-Za-z0-9_.+-]+\z/, executable) ->
        {:known, executable}

      true ->
        :unverified
    end
  end

  defp check_local(runtime, setting, :unverified, _tracker) do
    {:checked, "Workflow valid for #{runtime}. #{setting} executable unverified. Runtime authentication unverified."}
  end

  defp check_local(runtime, setting, {kind, configured}, tracker) do
    case System.find_executable(configured) do
      nil ->
        {:error, "Executable for #{setting} was not found on the worker. Install it or update #{setting}."}

      executable ->
        runtime |> local_auth_probe(kind, executable, tracker) |> auth_result(runtime, setting)
    end
  end

  defp local_auth_probe("codex", :codex_launch, executable, tracker) do
    if trusted_executable?(executable, "codex") do
      executable |> run_probe(["login", "status"], tracker) |> codex_auth_status()
    else
      :unverified
    end
  end

  defp local_auth_probe("claude_code", :known, executable, tracker) do
    if trusted_executable?(executable, "claude-agent-acp") do
      executable |> run_probe(["--cli", "auth", "status", "--json"], tracker) |> claude_auth_status()
    else
      :unverified
    end
  end

  defp local_auth_probe(_runtime, _kind, _executable, _tracker), do: :unverified

  defp trusted_executable?(executable, name) do
    case System.find_executable(name) do
      nil -> false
      installed -> Path.expand(executable) == Path.expand(installed)
    end
  end

  defp codex_auth_status({:ok, status, output}) do
    cond do
      status in [126, 127] -> :launch_failed
      Regex.match?(~r/^Not logged in\b/im, output) -> :missing
      Regex.match?(~r/^Logged in\b/im, output) and status == 0 -> :verified
      Regex.match?(~r/^(?:Error:\s*)?(?:Invalid API key|Authentication failed)\b/im, output) -> :rejected
      true -> :unverified
    end
  end

  defp codex_auth_status({:error, :launch_failed}), do: :launch_failed
  defp codex_auth_status(_result), do: :unverified

  defp claude_auth_status({:ok, status, output}) do
    case {status, Jason.decode(output)} do
      {0, {:ok, %{"loggedIn" => true}}} -> :verified
      {_, {:ok, %{"loggedIn" => false}}} -> :missing
      {status, _} when status in [126, 127] -> :launch_failed
      _ -> :unverified
    end
  end

  defp claude_auth_status({:error, :launch_failed}), do: :launch_failed
  defp claude_auth_status(_result), do: :unverified

  defp auth_result(:verified, runtime, _setting) do
    {:checked, "Workflow valid for #{runtime}. #{name(runtime)} authentication verified by the local CLI."}
  end

  defp auth_result(:unverified, runtime, _setting) do
    {:checked, "Workflow valid for #{runtime}. Launcher found. #{name(runtime)} authentication unverified."}
  end

  defp auth_result(:launch_failed, _runtime, setting) do
    {:error, "Executable for #{setting} could not start. Check its worker dependencies and permissions."}
  end

  defp auth_result(status, runtime, _setting) when status in [:missing, :rejected] do
    {:error, "#{name(runtime)} authentication #{status}. #{login_hint(runtime)}"}
  end

  defp name("codex"), do: "Codex"
  defp name("antigravity"), do: "Antigravity"
  defp name("claude_code"), do: "Claude Code"

  defp login_hint("codex"), do: "Run codex login as the worker user."
  defp login_hint("claude_code"), do: "Run claude-agent-acp --cli auth login as the worker user."

  defp check_remote_workers(_hosts, :unverified) do
    {:checked, "Workflow valid for codex. SSH worker executable and authentication unverified."}
  end

  defp check_remote_workers(hosts, {_kind, executable}) do
    quoted_executable = "'" <> String.replace(executable, "'", "'\"'\"'") <> "'"
    command = "command -v -- " <> quoted_executable <> " >/dev/null"

    hosts
    |> Enum.with_index(1)
    |> Enum.reduce_while(:ok, fn {host, index}, :ok ->
      case remote_check(host, command) do
        {:ok, 0, _} ->
          {:cont, :ok}

        {:ok, 1, _} ->
          {:halt, {:error, "Executable for codex.command was not found on worker.ssh_hosts entry #{index}."}}

        _ ->
          {:halt, {:error, "Could not check worker.ssh_hosts entry #{index}. Verify SSH access and Bash."}}
      end
    end)
    |> case do
      :ok -> {:checked, "Codex workflow valid. Launcher found on all SSH workers. Runtime authentication unverified."}
      error -> error
    end
  end

  defp remote_check(host, command) do
    with true <- safe_ssh_target?(host),
         {:ok, port} <- SSH.start_port(host, command, batch_check: true) do
      collect_probe(port)
    end
  rescue
    ArgumentError -> {:error, :launch_failed}
    ErlangError -> {:error, :launch_failed}
  end

  defp safe_ssh_target?(host) do
    target = String.trim(host)
    not String.starts_with?(target, "-") and Regex.match?(~r/\A[A-Za-z0-9_.@:\[\]%-]+\z/, target)
  end

  defp run_probe(executable, args, tracker) do
    secret_environment =
      Tracker.bind_agent_tools(tracker).secret_environment_names
      |> Enum.map(&{String.to_charlist(&1), false})

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:args, args},
        {:env, secret_environment},
        {:cd, System.tmp_dir!()}
      ])

    collect_probe(port)
  rescue
    ArgumentError -> {:error, :launch_failed}
    ErlangError -> {:error, :launch_failed}
  end

  defp collect_probe(port) do
    collect_probe(port, "", System.monotonic_time(:millisecond) + @probe_timeout_ms)
  after
    close_probe(port)
  end

  defp close_probe(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp collect_probe(port, output, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining > 0 do
      receive do
        {^port, {:data, data}} ->
          if byte_size(output) + byte_size(data) <= @probe_output_limit do
            collect_probe(port, output <> data, deadline)
          else
            {:error, :probe_output_limit}
          end

        {^port, {:exit_status, status}} ->
          {:ok, status, output}
      after
        remaining -> {:error, :probe_timeout}
      end
    else
      {:error, :probe_timeout}
    end
  end

  defp workflow_error({:invalid_workflow_config, message}), do: "Invalid workflow configuration. #{message}"
  defp workflow_error({:workflow_parse_error, _reason}), do: "WORKFLOW.md contains invalid YAML front matter."
  defp workflow_error(:workflow_front_matter_not_a_map), do: "WORKFLOW.md front matter must be a YAML map."
  defp workflow_error({:missing_workflow_file, _path, reason}), do: "Could not read the workflow file (#{reason})."
  defp workflow_error({:unsupported_tracker_kind, _kind}), do: "Choose a supported tracker.kind."
  defp workflow_error(reason) when is_atom(reason), do: "Invalid tracker configuration (#{reason})."
  defp workflow_error({reason, _detail}) when is_atom(reason), do: "Invalid tracker configuration (#{reason})."
  defp workflow_error(_reason), do: "Invalid tracker configuration."
end
