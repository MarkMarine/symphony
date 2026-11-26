defmodule SymphonyElixirWeb.AgentToolController do
  @moduledoc """
  HTTP endpoint for `SymphonyElixir.Agents.ToolBridge`: lets Claude Code and pi
  agents call the tracker's host-side tools with a per-session bearer token.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.Agents.ToolBridge

  @spec call(Conn.t(), map()) :: Conn.t()
  def call(conn, %{"tool" => tool} = params) do
    arguments = Map.drop(params, ["tool"])

    with {:ok, token} <- bearer_token(conn),
         {:ok, result} <- ToolBridge.execute(token, tool, arguments) do
      json(conn, result)
    else
      _ ->
        conn
        |> put_status(401)
        |> json(%{error: %{code: "unauthorized", message: "Missing or unknown agent tool token"}})
    end
  end

  defp bearer_token(conn) do
    case Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] when token != "" -> {:ok, String.trim(token)}
      _ -> :error
    end
  end
end
