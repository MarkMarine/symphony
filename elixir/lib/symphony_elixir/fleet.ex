defmodule SymphonyElixir.Fleet do
  @moduledoc """
  One list of every agent working the board, however it runs.

  Agents started by `devx work` or `devx loop` (Claude Code, Codex or pi on a laptop,
  in the NixOS agent box, or in a Codex cloud task) coordinate through Linear
  comments. Each comment ends with a marker line:

      devx-claim: <claim id>       the claim names the agent, machine and workspace
      devx-heartbeat: <claim id>   a checkpoint (`devx work status`)
      devx-release: <claim id>     done, need-human, release or a lost race

  A claim stays held until it is released. It is `active` while its newest claim or
  heartbeat comment is younger than the claim TTL (devx's `claim_ttl_minutes`,
  180 by default) and `stale` after that: devx agents may then claim the issue
  again, and the dashboard shows that the agent has gone quiet.

  Symphony's own sessions are projected into the same shape, so the dashboard and
  `/api/v1/state` show one list of agents.
  """

  @marker ~r/^devx-(claim|heartbeat|release): ([0-9a-f-]{36})\s*$/m
  @field ~r/^- (agent|machine|workspace): (.+?)\s*$/m
  @signature ~r/\n*_[^_\n]+ on [^_\n]+_\s*\z/
  @default_ttl_minutes 180

  @type agent :: %{
          source: String.t(),
          status: String.t(),
          agent: String.t() | nil,
          machine: String.t() | nil,
          workspace: String.t() | nil,
          issue_identifier: String.t() | nil,
          issue_url: String.t() | nil,
          issue_title: String.t() | nil,
          state: String.t() | nil,
          claim_id: String.t() | nil,
          claimed_at: String.t() | nil,
          last_seen_at: String.t() | nil,
          last_message: String.t() | nil
        }

  @doc """
  Agents holding unreleased devx claims on the given Linear issues.

  Each issue is a Linear GraphQL node with `identifier`, `title`, `url`,
  `state { name }` and `comments { nodes { body createdAt } }`.
  Options: `:claim_ttl_minutes` (default 180) and `:now`.
  """
  @spec devx_agents([map()], keyword()) :: [agent()]
  def devx_agents(issues, opts \\ []) when is_list(issues) do
    ttl_seconds = Keyword.get(opts, :claim_ttl_minutes, @default_ttl_minutes) * 60
    now = Keyword.get(opts, :now) || DateTime.utc_now()

    issues
    |> Enum.flat_map(&issue_claims/1)
    |> Enum.map(&put_status(&1, now, ttl_seconds))
    |> sort_newest_first()
  end

  @doc """
  Symphony's own sessions, from the presenter's `running` and `blocked` entries,
  in the same shape as devx agents. `local_host` names this machine for sessions
  that did not run on an SSH worker.
  """
  @spec symphony_agents([map()], [map()], String.t()) :: [agent()]
  def symphony_agents(running, blocked, local_host) do
    Enum.map(running, &symphony_agent(&1, "active", local_host)) ++
      Enum.map(blocked, &symphony_agent(&1, "blocked", local_host))
  end

  @doc "devx agents and Symphony sessions together, newest activity first."
  @spec merge([agent()], [agent()]) :: [agent()]
  def merge(symphony, devx), do: sort_newest_first(symphony ++ devx)

  @doc false
  @spec parse_claim_body(String.t()) :: map()
  def parse_claim_body(body) when is_binary(body) do
    @field
    |> Regex.scan(body)
    |> Enum.reduce(%{}, fn [_line, key, value], acc ->
      Map.put_new(acc, String.to_existing_atom(key), value |> String.trim("`") |> blank_to_nil())
    end)
  end

  @doc false
  @spec checkpoint_message(String.t()) :: String.t() | nil
  def checkpoint_message(body) when is_binary(body) do
    body
    |> String.replace(@marker, "")
    |> String.trim()
    |> String.replace(@signature, "")
    |> String.trim()
    |> blank_to_nil()
  end

  defp issue_claims(issue) do
    comments =
      issue
      |> get_in(["comments", "nodes"])
      |> List.wrap()
      |> Enum.flat_map(&timed_comment/1)
      |> Enum.sort_by(fn {at, _body} -> at end, DateTime)

    {claims, released} = Enum.reduce(comments, {%{}, MapSet.new()}, &apply_comment/2)

    claims
    |> Map.drop(MapSet.to_list(released))
    |> Map.values()
    |> Enum.map(&Map.merge(&1, issue_fields(issue)))
  end

  defp timed_comment(%{"body" => body, "createdAt" => created_at}) when is_binary(body) and is_binary(created_at) do
    case DateTime.from_iso8601(created_at) do
      {:ok, at, _offset} -> [{at, body}]
      _ -> []
    end
  end

  defp timed_comment(_comment), do: []

  defp apply_comment({at, body}, acc) do
    @marker
    |> Regex.scan(body)
    |> Enum.reduce(acc, fn [_line, kind, claim_id], inner -> apply_marker(kind, claim_id, at, body, inner) end)
  end

  defp apply_marker("claim", claim_id, at, body, {claims, released}) do
    if Map.has_key?(claims, claim_id) do
      {claims, released}
    else
      fields = parse_claim_body(body)

      claim = %{
        source: "devx",
        agent: Map.get(fields, :agent),
        machine: Map.get(fields, :machine),
        workspace: Map.get(fields, :workspace),
        claim_id: claim_id,
        claimed_at: at,
        last_seen_at: at,
        last_message: nil
      }

      {Map.put(claims, claim_id, claim), released}
    end
  end

  defp apply_marker("heartbeat", claim_id, at, body, {claims, released}) do
    case Map.fetch(claims, claim_id) do
      {:ok, claim} ->
        claim = %{claim | last_seen_at: at, last_message: checkpoint_message(body) || claim.last_message}
        {Map.put(claims, claim_id, claim), released}

      :error ->
        {claims, released}
    end
  end

  defp apply_marker("release", claim_id, _at, _body, {claims, released}) do
    {claims, MapSet.put(released, claim_id)}
  end

  defp issue_fields(issue) do
    %{
      issue_identifier: issue["identifier"],
      issue_url: issue["url"],
      issue_title: issue["title"],
      state: get_in(issue, ["state", "name"])
    }
  end

  defp put_status(claim, now, ttl_seconds) do
    status = if DateTime.diff(now, claim.last_seen_at, :second) <= ttl_seconds, do: "active", else: "stale"

    %{claim | claimed_at: iso8601(claim.claimed_at), last_seen_at: iso8601(claim.last_seen_at)}
    |> Map.put(:status, status)
  end

  defp symphony_agent(entry, status, local_host) do
    %{
      source: "symphony",
      status: status,
      agent: Map.get(entry, :agent_kind) || "codex",
      machine: Map.get(entry, :worker_host) || local_host,
      workspace: Map.get(entry, :workspace_path),
      issue_identifier: Map.get(entry, :issue_identifier),
      issue_url: Map.get(entry, :issue_url),
      issue_title: nil,
      state: Map.get(entry, :state),
      claim_id: Map.get(entry, :session_id),
      claimed_at: Map.get(entry, :started_at) || Map.get(entry, :blocked_at),
      last_seen_at: Map.get(entry, :last_event_at) || Map.get(entry, :started_at) || Map.get(entry, :blocked_at),
      last_message: Map.get(entry, :last_message) || Map.get(entry, :error)
    }
  end

  # ISO 8601 UTC strings of equal precision sort chronologically; nil sorts last.
  defp sort_newest_first(agents) do
    Enum.sort_by(agents, &{&1.last_seen_at != nil, &1.last_seen_at || ""}, :desc)
  end

  defp iso8601(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
