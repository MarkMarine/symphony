defmodule SymphonyElixir.Fleet.Poller do
  @moduledoc """
  Polls Linear for devx agent claims so the dashboard can show agents that
  Symphony did not start (`devx loop` on laptops, the agent box, Codex cloud tasks).

  Enabled by a `fleet` block in WORKFLOW.md (see `SymphonyElixir.Config.Schema.Fleet`).
  One query per interval reads the issues in the fleet's working states with only
  the comments that carry devx markers. Nothing is written to Linear.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.{Config, Fleet}
  alias SymphonyElixir.Linear.Client
  alias SymphonyElixirWeb.ObservabilityPubSub

  @disabled_recheck_ms 60_000
  @page_size 25
  @max_pages 8

  @query """
  query SymphonyFleet($filter: IssueFilter!, $first: Int!, $after: String) {
    issues(first: $first, after: $after, filter: $filter) {
      nodes {
        identifier
        title
        url
        state {
          name
        }
        comments(first: 100, filter: {body: {contains: "devx-"}}) {
          nodes {
            body
            createdAt
          }
        }
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
  }
  """

  @type snapshot :: %{
          enabled: boolean(),
          agents: [Fleet.agent()],
          fetched_at: String.t() | nil,
          error: String.t() | nil
        }

  @empty %{enabled: false, agents: [], fetched_at: nil, error: nil}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "The latest fleet snapshot; a disabled, empty one when the poller is not running."
  @spec snapshot(GenServer.name(), timeout()) :: snapshot()
  def snapshot(server, timeout \\ 1_000) do
    GenServer.call(server, :snapshot, timeout)
  catch
    :exit, _reason -> @empty
  end

  @doc "The Linear issue filter for fleet settings, or nil when the fleet is off."
  @spec issue_filter(map() | nil, map() | nil) :: map() | nil
  def issue_filter(%{} = fleet, tracker) do
    if enabled?(fleet), do: build_filter(fleet, tracker), else: nil
  end

  def issue_filter(_fleet, _tracker), do: nil

  @doc "Fetch fleet issues page by page through `graphql_fun`, which behaves like `Linear.Client.graphql/2`."
  @spec fetch_issues(map(), (String.t(), map() -> {:ok, map()} | {:error, term()})) ::
          {:ok, [map()]} | {:error, term()}
  def fetch_issues(filter, graphql_fun) when is_map(filter) and is_function(graphql_fun, 2) do
    fetch_pages(filter, graphql_fun, nil, [], @max_pages)
  end

  @impl true
  def init(opts) do
    state = %{
      snapshot: @empty,
      task: nil,
      settings_fun: Keyword.get(opts, :settings_fun, &default_settings/0),
      graphql_fun: Keyword.get(opts, :graphql_fun, &Client.graphql/2),
      clock: Keyword.get(opts, :clock, &DateTime.utc_now/0)
    }

    send(self(), :poll)
    {:ok, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, state.snapshot, state}

  # The Linear request runs in a task so snapshot calls are answered while it is in flight.
  @impl true
  def handle_info(:poll, state) do
    {fleet, tracker} = state.settings_fun.()

    case issue_filter(fleet, tracker) do
      nil ->
        Process.send_after(self(), :poll, @disabled_recheck_ms)
        {:noreply, put_snapshot(state, @empty)}

      filter ->
        graphql_fun = state.graphql_fun
        task = Task.async(fn -> safe_fetch(filter, graphql_fun) end)
        {:noreply, %{state | task: {task.ref, fleet, state.clock.()}}}
    end
  end

  def handle_info({ref, result}, %{task: {ref, fleet, now}} = state) do
    Process.demonitor(ref, [:flush])
    finish_poll(state, fleet, fleet_snapshot(result, fleet, now, state.snapshot))
  end

  def handle_info(_message, state), do: {:noreply, state}

  # Task.async links the task to this server; a raise in the request must not take it down.
  defp safe_fetch(filter, graphql_fun) do
    fetch_issues(filter, graphql_fun)
  rescue
    error -> {:error, {:fleet_poll_crashed, Exception.message(error)}}
  end

  defp finish_poll(state, fleet, snapshot) do
    Process.send_after(self(), :poll, fleet.interval_ms)
    {:noreply, put_snapshot(%{state | task: nil}, snapshot)}
  end

  defp put_snapshot(state, snapshot) do
    if snapshot != state.snapshot, do: ObservabilityPubSub.broadcast_update()
    %{state | snapshot: snapshot}
  end

  defp fleet_snapshot({:ok, issues}, fleet, now, _previous) do
    agents = Fleet.devx_agents(issues, claim_ttl_minutes: fleet.claim_ttl_minutes, now: now)
    %{enabled: true, agents: agents, fetched_at: iso8601(now), error: nil}
  end

  defp fleet_snapshot({:error, reason}, _fleet, _now, previous) do
    Logger.warning("Fleet poll failed: #{inspect(reason)}")
    # Keep the last good agents so a transient Linear failure does not blank the view.
    %{previous | enabled: true, error: format_error(reason)}
  end

  defp iso8601(now), do: now |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp fetch_pages(_filter, _graphql_fun, _after, acc, 0), do: {:ok, acc}

  defp fetch_pages(filter, graphql_fun, after_cursor, acc, pages_left) do
    variables = %{"filter" => filter, "first" => @page_size, "after" => after_cursor}

    case graphql_fun.(@query, variables) do
      {:ok, %{"data" => %{"issues" => %{"nodes" => nodes} = issues}}} when is_list(nodes) ->
        case issues["pageInfo"] do
          %{"hasNextPage" => true, "endCursor" => cursor} when is_binary(cursor) ->
            fetch_pages(filter, graphql_fun, cursor, acc ++ nodes, pages_left - 1)

          _ ->
            {:ok, acc ++ nodes}
        end

      {:ok, %{"errors" => errors}} ->
        {:error, {:linear_graphql_errors, errors}}

      {:ok, _body} ->
        {:error, :linear_unexpected_response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp enabled?(fleet), do: fleet.enabled == true or is_binary(fleet.team)

  defp build_filter(fleet, tracker) do
    scope =
      cond do
        is_binary(fleet.team) ->
          put_projects(%{"team" => %{"key" => %{"eq" => fleet.team}}}, fleet.projects)

        is_map(tracker) and is_binary(Map.get(tracker, :project_slug)) ->
          %{"project" => %{"slugId" => %{"eq" => tracker.project_slug}}}

        true ->
          nil
      end

    scope && Map.put(scope, "state", %{"name" => %{"in" => fleet.states}})
  end

  defp put_projects(filter, [_ | _] = projects), do: Map.put(filter, "project", %{"name" => %{"in" => projects}})
  defp put_projects(filter, _projects), do: filter

  defp format_error({:linear_graphql_errors, [%{"message" => message} | _]}) when is_binary(message),
    do: "Linear: " <> message

  defp format_error(reason), do: inspect(reason)

  defp default_settings, do: fleet_settings(Config.settings())

  @doc false
  @spec fleet_settings({:ok, map()} | {:error, term()}) :: {map() | nil, map() | nil}
  def fleet_settings({:ok, settings}), do: {settings.fleet, settings.tracker}
  # An invalid or missing workflow already surfaces elsewhere; the fleet just stays off.
  def fleet_settings(_error), do: {nil, nil}
end
