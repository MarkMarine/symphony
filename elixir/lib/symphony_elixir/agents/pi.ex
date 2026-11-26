defmodule SymphonyElixir.Agents.Pi do
  @moduledoc """
  pi coding agent adapter.

  Runs one long-lived `pi --mode rpc` process per issue run. Each turn sends a
  `prompt` command and reads RPC events until `agent_end`, so continuation
  turns keep the conversation context.

  Configure with the `pi` section of WORKFLOW.md:

      pi:
        command: pi --mode rpc --provider anthropic --model claude-sonnet-4-5
        turn_timeout_ms: 3600000

  Extension UI requests that need an answer (select, confirm, input, editor)
  are cancelled, because Symphony runs unattended. Tracker tools are offered
  through `SymphonyElixir.Agents.ToolBridge`.
  """

  @behaviour SymphonyElixir.AgentAdapter

  require Logger

  alias SymphonyElixir.Agents.{StdioPort, ToolBridge}
  alias SymphonyElixir.Config

  @turn 1
  @input 2
  @output 3
  @dialog_methods ~w(select confirm input editor)

  @impl true
  def start_session(workspace, opts) do
    worker_host = Keyword.get(opts, :worker_host)
    bridge = ToolBridge.register(Keyword.get(opts, :issue), worker_host)

    case StdioPort.start(workspace, worker_host, Config.settings!().pi.command,
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
    session_id = "pi-#{metadata[:codex_app_server_pid] || "local"}-turn-#{turn_number}"
    request_id = "symphony-turn-#{turn_number}"

    StdioPort.send_json(port, %{"id" => request_id, "type" => "prompt", "message" => text})

    Logger.info("pi turn started for #{issue_context(issue)} session_id=#{session_id}")
    emit(on_message, :session_started, %{session_id: session_id, thread_id: session_id, turn_id: "#{turn_number}"}, metadata)

    case await_agent_end(session, on_message, request_id, Config.settings!().pi.turn_timeout_ms) do
      {:ok, result} ->
        {:ok, %{result: result, session_id: session_id, thread_id: session_id, turn_id: "#{turn_number}"}}

      {:error, reason} ->
        Logger.warning("pi turn ended with error for #{issue_context(issue)}: #{inspect(reason)}")
        emit(on_message, :turn_ended_with_error, %{session_id: session_id, reason: reason}, metadata)
        {:error, reason}
    end
  end

  @impl true
  def stop_session(%{port: port} = session) do
    ToolBridge.unregister(Map.get(session, :bridge_token))
    StdioPort.stop(port)
  end

  defp await_agent_end(%{port: port} = session, on_message, request_id, timeout_ms) do
    case StdioPort.next_line(port, timeout_ms) do
      {:line, line} ->
        case Jason.decode(line) do
          {:ok, %{} = payload} ->
            handle_event(session, on_message, request_id, timeout_ms, payload, line)

          _ ->
            StdioPort.log_non_json(line, "pi")
            await_agent_end(session, on_message, request_id, timeout_ms)
        end

      {:exit, status} ->
        {:error, {:port_exit, status}}

      :timeout ->
        {:error, :turn_timeout}
    end
  end

  defp handle_event(session, on_message, _request_id, _timeout_ms, %{"type" => "agent_end"} = payload, line) do
    usage = add_usage(session.counters, Map.get(payload, "messages", []))
    event_payload = Map.merge(payload, %{"method" => "turn/completed", "usage" => usage})

    case last_assistant_error(Map.get(payload, "messages", [])) do
      nil ->
        emit(on_message, :turn_completed, %{payload: event_payload, raw: line, details: payload, usage: usage}, session.metadata)
        {:ok, :turn_completed}

      error ->
        emit(on_message, :turn_failed, %{payload: event_payload, raw: line, details: payload}, session.metadata)
        {:error, {:turn_failed, error}}
    end
  end

  defp handle_event(
         session,
         on_message,
         request_id,
         timeout_ms,
         %{"type" => "response", "success" => false} = payload,
         line
       ) do
    if payload["id"] in [nil, request_id] and payload["command"] in [nil, "prompt"] do
      emit(on_message, :startup_failed, %{reason: payload["error"], payload: payload, raw: line}, session.metadata)
      {:error, {:prompt_rejected, payload["error"]}}
    else
      emit(on_message, :notification, %{payload: payload, raw: line}, session.metadata)
      await_agent_end(session, on_message, request_id, timeout_ms)
    end
  end

  defp handle_event(
         session,
         on_message,
         request_id,
         timeout_ms,
         %{"type" => "extension_ui_request", "id" => id, "method" => method} = payload,
         line
       )
       when method in @dialog_methods do
    StdioPort.send_json(session.port, %{"type" => "extension_ui_response", "id" => id, "cancelled" => true})
    emit(on_message, :notification, %{payload: payload, raw: line}, session.metadata)
    await_agent_end(session, on_message, request_id, timeout_ms)
  end

  defp handle_event(session, on_message, request_id, timeout_ms, payload, line) do
    emit(on_message, :notification, %{payload: payload, raw: line}, session.metadata)
    await_agent_end(session, on_message, request_id, timeout_ms)
  end

  defp add_usage(counters, messages) when is_list(messages) do
    Enum.each(messages, fn
      %{"role" => "assistant", "usage" => %{} = usage} ->
        input = int(usage["input"]) + int(usage["cacheRead"]) + int(usage["cacheWrite"])
        :counters.add(counters, @input, input)
        :counters.add(counters, @output, int(usage["output"]))

      _message ->
        :ok
    end)

    input = :counters.get(counters, @input)
    output = :counters.get(counters, @output)
    %{"input_tokens" => input, "output_tokens" => output, "total_tokens" => input + output}
  end

  defp add_usage(counters, _messages), do: add_usage(counters, [])

  defp last_assistant_error(messages) when is_list(messages) do
    messages
    |> Enum.filter(&match?(%{"role" => "assistant"}, &1))
    |> List.last()
    |> case do
      %{"stopReason" => "error"} = message -> message["errorMessage"] || "pi agent stopped with an error"
      _ -> nil
    end
  end

  defp last_assistant_error(_messages), do: nil

  defp int(value) when is_integer(value), do: value
  defp int(_value), do: 0

  defp emit(on_message, event, details, metadata) do
    on_message.(metadata |> Map.merge(details) |> Map.put(:event, event) |> Map.put(:timestamp, DateTime.utc_now()))
  end

  defp issue_context(%{id: id, identifier: identifier}), do: "issue_id=#{id} issue_identifier=#{identifier}"
  defp issue_context(_issue), do: "issue=unknown"
end
