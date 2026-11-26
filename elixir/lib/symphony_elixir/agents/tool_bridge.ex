defmodule SymphonyElixir.Agents.ToolBridge do
  @moduledoc """
  Exposes the tracker's host-side agent tools (for Linear, `linear_graphql`) to
  agents that do not speak the Codex dynamic-tool protocol.

  Each agent session gets a random bearer token. The agent calls
  `POST <SYMPHONY_TOOL_URL>/<tool>` with that token and a JSON body of tool
  arguments; Symphony runs the tool with its own tracker credentials, so the
  tracker API key never enters the agent's environment.

  The endpoint is served by the observability HTTP server, so it needs
  `server.port` (or `--port`). For SSH workers, set `agent.tool_bridge_url`
  to an address the worker can reach and bind `server.host` accordingly.
  """

  use Agent

  require Logger

  alias SymphonyElixir.{Config, HttpServer, Tracker}

  @token_bytes 32

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  @type registration :: %{
          token: String.t(),
          binding: map(),
          env: %{String.t() => String.t()},
          preface: String.t()
        }

  @doc """
  Binds the tracker tools for a session. Returns the token, the binding, the
  environment to give the agent, and a prompt preface describing the tools.
  """
  @spec register(map() | nil, String.t() | nil) :: registration()
  def register(issue, worker_host) do
    binding = Tracker.bind_agent_tools()
    token = @token_bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

    tool_specs = binding.tool_specs || []

    case base_url(worker_host) do
      {:ok, url} when tool_specs != [] ->
        ensure_started()
        Agent.update(__MODULE__, &Map.put(&1, token, %{binding: binding, issue: issue}))

        %{
          token: token,
          binding: binding,
          env: %{"SYMPHONY_TOOL_URL" => url, "SYMPHONY_TOOL_TOKEN" => token},
          preface: preface(tool_specs)
        }

      {:ok, _url} ->
        %{token: token, binding: binding, env: %{}, preface: ""}

      {:error, reason} ->
        Logger.warning("Tracker tool bridge unavailable (#{reason}); the agent will not get tracker tools")

        %{token: token, binding: binding, env: %{}, preface: ""}
    end
  end

  @spec unregister(String.t() | nil) :: :ok
  def unregister(token) when is_binary(token) do
    if Process.whereis(__MODULE__), do: Agent.update(__MODULE__, &Map.delete(&1, token))
    :ok
  end

  def unregister(_token), do: :ok

  @spec execute(String.t(), String.t(), term()) :: {:ok, map()} | {:error, :unauthorized}
  def execute(token, tool, arguments) when is_binary(token) do
    case Process.whereis(__MODULE__) && Agent.get(__MODULE__, &Map.get(&1, token)) do
      %{binding: binding, issue: issue} ->
        {:ok, Tracker.execute_bound_agent_tool(binding, tool, arguments, issue: issue)}

      _ ->
        {:error, :unauthorized}
    end
  end

  def execute(_token, _tool, _arguments), do: {:error, :unauthorized}

  @doc false
  @spec preface([map()]) :: String.t()
  def preface([]), do: ""

  def preface(tool_specs) do
    tools =
      Enum.map_join(tool_specs, "\n\n", fn spec ->
        """
        ### #{spec["name"]}
        #{spec["description"]}

        Arguments (JSON Schema):
        #{Jason.encode!(spec["inputSchema"] || %{}, pretty: true)}
        """
      end)

    """
    ## Tracker tools

    Symphony gives you host-side tracker tools over HTTP. The tracker API key is
    not in your environment; use these tools for every tracker read or write.
    Call a tool with the JSON arguments as the request body:

        curl -sS -X POST "$SYMPHONY_TOOL_URL/<tool name>" \\
          -H "Authorization: Bearer $SYMPHONY_TOOL_TOKEN" \\
          -H "Content-Type: application/json" \\
          --data-binary @- <<'JSON'
        {"query": "..."}
        JSON

    The response is JSON with `success` and `output`.

    #{tools}
    ---

    """
  end

  defp base_url(worker_host) do
    configured = Config.settings!().agent.tool_bridge_url

    cond do
      is_binary(configured) and String.trim(configured) != "" ->
        {:ok, String.trim_trailing(String.trim(configured), "/") <> "/api/v1/agent_tools"}

      is_binary(worker_host) ->
        {:error, "agent.tool_bridge_url is required for SSH workers"}

      true ->
        case HttpServer.bound_port() do
          port when is_integer(port) and port > 0 ->
            {:ok, "http://127.0.0.1:#{port}/api/v1/agent_tools"}

          _ ->
            {:error, "server.port is not set"}
        end
    end
  end

  defp ensure_started do
    case Process.whereis(__MODULE__) do
      nil ->
        case start_link() do
          {:ok, pid} ->
            Process.unlink(pid)
            :ok

          {:error, {:already_started, _pid}} ->
            :ok
        end

      _pid ->
        :ok
    end
  end
end
