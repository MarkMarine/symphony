defmodule SymphonyElixir.AgentAdapter do
  @moduledoc """
  Behaviour for the coding agents Symphony can drive, and selection of the
  adapter for an issue.

  An adapter owns one long-lived agent process per issue run. The agent runner
  calls `start_session/2` once, `run_turn/4` for every turn, then
  `stop_session/1`. Adapters report progress by calling the `:on_message`
  callback with maps that carry at least `:event` and `:timestamp`, the same
  shape the Codex app-server client emits, so the orchestrator and dashboard
  work unchanged.

  Selection order for an issue:

    1. `agent.kind_by_label`: the first issue label that maps to a kind.
    2. `agent.kind` (default `"codex"`).
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.Tracker.Issue

  @type session :: map()

  @callback start_session(workspace :: Path.t(), opts :: keyword()) :: {:ok, session()} | {:error, term()}
  @callback run_turn(session(), prompt :: String.t(), issue :: map(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}
  @callback stop_session(session()) :: :ok

  @adapters %{
    "codex" => SymphonyElixir.Agents.Codex,
    "claude" => SymphonyElixir.Agents.ClaudeCode,
    "pi" => SymphonyElixir.Agents.Pi
  }

  @spec adapters() :: %{String.t() => module()}
  def adapters, do: @adapters

  @spec for_issue(Issue.t() | map()) :: module()
  def for_issue(issue) do
    issue
    |> kind_for_issue()
    |> adapter_for_kind!()
  end

  @spec kind_for_issue(Issue.t() | map()) :: String.t()
  def kind_for_issue(issue) do
    agent_settings = Config.settings!().agent
    kind_by_label = agent_settings.kind_by_label || %{}

    label_kind =
      issue
      |> issue_labels()
      |> Enum.find_value(fn label -> Map.get(kind_by_label, normalize(label)) end)

    label_kind || agent_settings.kind || "codex"
  end

  @spec adapter_for_kind!(String.t()) :: module()
  def adapter_for_kind!(kind) do
    case Map.fetch(@adapters, kind) do
      {:ok, adapter} -> adapter
      :error -> raise ArgumentError, "unsupported agent kind: #{inspect(kind)}"
    end
  end

  defp issue_labels(%{labels: labels}) when is_list(labels), do: Enum.filter(labels, &is_binary/1)
  defp issue_labels(_issue), do: []

  defp normalize(label), do: label |> String.trim() |> String.downcase()
end
