defmodule SymphonyElixir.Agents.ClaudeCode do
  @moduledoc """
  Claude Code adapter.

  Runs one long-lived `claude -p --input-format stream-json --output-format
  stream-json --verbose` process per issue run. Each turn writes one user
  message to stdin and reads stream-json events until the `result` event, so
  continuation turns keep the conversation context, like Codex threads.

  Configure with the `claude` section of WORKFLOW.md:

      claude:
        command: claude -p --input-format stream-json --output-format stream-json --verbose --permission-mode bypassPermissions
        turn_timeout_ms: 3600000

  Tracker tools are offered through `SymphonyElixir.Agents.ToolBridge`.
  """

  @behaviour SymphonyElixir.AgentAdapter

  require Logger

  alias SymphonyElixir.Agents.{StdioPort, ToolBridge}
  alias SymphonyElixir.Config

  # Counter slots: turn number, cumulative input tokens, cumulative output tokens.
  @turn 1
  @input 2
  @output 3

  @impl true
  def start_session(workspace, opts) do
    worker_host = Keyword.get(opts, :worker_host)
    bridge = ToolBridge.register(Keyword.get(opts, :issue), worker_host)

    case StdioPort.start(workspace, worker_host, Config.settings!().claude.command,
           unset_env: bridge.binding.secret_environment_names || [],
           env: bridge.env
         ) do
      {:ok, %{port: port, workspace: expanded_workspace, metadata: metadata}} ->
        {:ok,
         %{
           port: port,
           workspace: expanded_workspace,
           worker_host: worker_host,
           metadata: metadata,
           counters: :counters.new(3, []),
           bridge_token: bridge.token,
           preface: bridge.preface
         }}

      {:error, reason} ->
        ToolBridge.unregister(bridge.token)
        {:error, reason}
    end
  end

  @impl true
  def run_turn(%{port: port, metadata: metadata, counters: counters} = session, prompt, issue, opts) do
    on_message = Keyword.get(opts, :on_message, fn _message -> :ok end)
    :counters.add(counters, @turn, 1)
    turn_number = :counters.get(counters, @turn)
    text = if turn_number == 1, do: session.preface <> prompt, else: prompt
    session_id = "claude-#{metadata[:codex_app_server_pid] || "local"}-turn-#{turn_number}"

    StdioPort.send_json(port, %{
      "type" => "user",
      "message" => %{"role" => "user", "content" => [%{"type" => "text", "text" => text}]}
    })

    Logger.info("Claude Code turn started for #{issue_context(issue)} session_id=#{session_id}")
    emit(on_message, :session_started, %{session_id: session_id, thread_id: session_id, turn_id: "#{turn_number}"}, metadata)

    case await_result(session, on_message, Config.settings!().claude.turn_timeout_ms) do
      {:ok, result} ->
        {:ok, %{result: result, session_id: session_id, thread_id: session_id, turn_id: "#{turn_number}"}}

      {:error, reason} ->
        Logger.warning("Claude Code turn ended with error for #{issue_context(issue)}: #{inspect(reason)}")
        emit(on_message, :turn_ended_with_error, %{session_id: session_id, reason: reason}, metadata)
        {:error, reason}
    end
  end

  @impl true
  def stop_session(%{port: port} = session) do
    ToolBridge.unregister(Map.get(session, :bridge_token))
    StdioPort.stop(port)
  end

  defp await_result(%{port: port, metadata: metadata} = session, on_message, timeout_ms) do
    case StdioPort.next_line(port, timeout_ms) do
      {:line, line} ->
        case Jason.decode(line) do
          {:ok, %{"type" => "result"} = payload} ->
            handle_result(session, on_message, payload, line)

          {:ok, %{} = payload} ->
            emit(on_message, :notification, %{payload: payload, raw: line}, metadata)
            await_result(session, on_message, timeout_ms)

          _ ->
            StdioPort.log_non_json(line, "claude")
            await_result(session, on_message, timeout_ms)
        end

      {:exit, status} ->
        {:error, {:port_exit, status}}

      :timeout ->
        {:error, :turn_timeout}
    end
  end

  defp handle_result(%{counters: counters, metadata: metadata}, on_message, payload, line) do
    usage = Map.get(payload, "usage") || %{}

    input =
      int(usage["input_tokens"]) + int(usage["cache_creation_input_tokens"]) +
        int(usage["cache_read_input_tokens"])

    :counters.add(counters, @input, input)
    :counters.add(counters, @output, int(usage["output_tokens"]))

    cumulative = cumulative_usage(counters)
    event_payload = Map.merge(payload, %{"method" => "turn/completed", "usage" => cumulative})

    if payload["is_error"] == true or payload["subtype"] not in [nil, "success"] do
      emit(on_message, :turn_failed, %{payload: event_payload, raw: line, details: payload}, metadata)
      {:error, {:turn_failed, Map.take(payload, ["subtype", "result", "errors"])}}
    else
      emit(on_message, :turn_completed, %{payload: event_payload, raw: line, details: payload, usage: cumulative}, metadata)
      {:ok, :turn_completed}
    end
  end

  defp cumulative_usage(counters) do
    input = :counters.get(counters, @input)
    output = :counters.get(counters, @output)
    %{"input_tokens" => input, "output_tokens" => output, "total_tokens" => input + output}
  end

  defp int(value) when is_integer(value), do: value
  defp int(_value), do: 0

  defp emit(on_message, event, details, metadata) do
    on_message.(metadata |> Map.merge(details) |> Map.put(:event, event) |> Map.put(:timestamp, DateTime.utc_now()))
  end

  defp issue_context(%{id: id, identifier: identifier}), do: "issue_id=#{id} issue_identifier=#{identifier}"
  defp issue_context(_issue), do: "issue=unknown"
end
