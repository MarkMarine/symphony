defmodule SymphonyElixir.Agents.Codex do
  @moduledoc """
  Codex adapter: the original Codex app-server client.
  """

  @behaviour SymphonyElixir.AgentAdapter

  alias SymphonyElixir.Codex.AppServer

  @impl true
  def start_session(workspace, opts), do: AppServer.start_session(workspace, opts)

  @impl true
  def run_turn(session, prompt, issue, opts), do: AppServer.run_turn(session, prompt, issue, opts)

  @impl true
  def stop_session(session), do: AppServer.stop_session(session)
end
