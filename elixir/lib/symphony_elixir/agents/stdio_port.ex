defmodule SymphonyElixir.Agents.StdioPort do
  @moduledoc """
  Shared process plumbing for agents that speak newline-delimited JSON over
  stdio (Claude Code stream-json, pi RPC mode).

  Launches the configured command with `bash -lc` in the workspace, locally or
  over SSH, with tracker secrets removed from the environment and the tool
  bridge variables added.
  """

  require Logger

  alias SymphonyElixir.{Codex.AppServer, SSH}

  @port_line_bytes 1_048_576
  @max_log_bytes 1_000

  @type line_result :: {:line, String.t()} | {:exit, integer()} | :timeout

  @spec start(Path.t(), String.t() | nil, String.t(), keyword()) ::
          {:ok, %{port: port(), workspace: Path.t(), metadata: map()}} | {:error, term()}
  def start(workspace, worker_host, command, opts \\ []) when is_binary(command) do
    unset_names = opts |> Keyword.get(:unset_env, []) |> valid_environment_names()
    env = opts |> Keyword.get(:env, %{}) |> Enum.filter(fn {name, _} -> valid_environment_name?(name) end)

    with {:ok, expanded_workspace} <- AppServer.validate_workspace_cwd(workspace, worker_host),
         {:ok, port} <- open_port(expanded_workspace, worker_host, command, unset_names, env) do
      {:ok, %{port: port, workspace: expanded_workspace, metadata: metadata(port, worker_host)}}
    end
  end

  @spec send_json(port(), map()) :: true
  def send_json(port, message) when is_port(port) do
    Port.command(port, Jason.encode!(message) <> "\n")
  end

  @doc """
  Waits for the next complete stdout line. `pending` carries a partial line
  between calls.
  """
  @spec next_line(port(), non_neg_integer()) :: line_result()
  def next_line(port, timeout_ms), do: next_line(port, timeout_ms, "")

  defp next_line(port, timeout_ms, pending) do
    receive do
      {^port, {:data, {:eol, chunk}}} -> {:line, pending <> to_string(chunk)}
      {^port, {:data, {:noeol, chunk}}} -> next_line(port, timeout_ms, pending <> to_string(chunk))
      {^port, {:exit_status, status}} -> {:exit, status}
    after
      timeout_ms -> :timeout
    end
  end

  @spec stop(port()) :: :ok
  def stop(port) when is_port(port) do
    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        try do
          Port.close(port)
          :ok
        rescue
          ArgumentError -> :ok
        end
    end
  end

  def stop(_port), do: :ok

  @spec log_non_json(String.t(), String.t()) :: :ok
  def log_non_json(line, label) do
    text = String.slice(line, 0, @max_log_bytes)

    if String.trim(text) != "" do
      Logger.debug("#{label} non-JSON output: #{text}")
    end

    :ok
  end

  defp open_port(workspace, nil, command, unset_names, env) do
    case System.find_executable("bash") do
      nil ->
        {:error, :bash_not_found}

      executable ->
        port_env =
          Enum.map(unset_names, fn name -> {String.to_charlist(name), false} end) ++
            Enum.map(env, fn {name, value} -> {String.to_charlist(name), String.to_charlist(value)} end)

        port =
          Port.open(
            {:spawn_executable, String.to_charlist(executable)},
            [
              :binary,
              :exit_status,
              :stderr_to_stdout,
              args: [~c"-lc", String.to_charlist(launch_command(nil, command, unset_names, []))],
              cd: String.to_charlist(workspace),
              env: port_env,
              line: @port_line_bytes
            ]
          )

        {:ok, port}
    end
  end

  defp open_port(workspace, worker_host, command, unset_names, env) when is_binary(worker_host) do
    SSH.start_port(worker_host, launch_command(workspace, command, unset_names, env), line: @port_line_bytes)
  end

  defp launch_command(workspace, command, unset_names, env) do
    [
      workspace && "cd #{shell_escape(workspace)}",
      unset_names != [] && "unset " <> Enum.join(unset_names, " "),
      env != [] && "export " <> Enum.map_join(env, " ", fn {name, value} -> "#{name}=#{shell_escape(value)}" end),
      "exec #{command}"
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" && ")
  end

  defp metadata(port, worker_host) do
    base =
      case :erlang.port_info(port, :os_pid) do
        {:os_pid, os_pid} -> %{codex_app_server_pid: to_string(os_pid)}
        _ -> %{}
      end

    if is_binary(worker_host), do: Map.put(base, :worker_host, worker_host), else: base
  end

  defp valid_environment_names(names), do: Enum.filter(names, &valid_environment_name?/1)

  defp valid_environment_name?(name),
    do: is_binary(name) and String.match?(name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/)

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
