defmodule SymphonyElixir.FleetPollerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Fleet.Poller

  @claim_id "11111111-1111-4111-8111-111111111111"
  @now ~U[2026-11-25 12:00:00Z]
  @in_progress %{"name" => %{"in" => ["In Progress"]}}

  defp claimed_issue(identifier) do
    %{
      "identifier" => identifier,
      "title" => "Fix it",
      "url" => "https://linear.app/payonce/issue/#{identifier}",
      "state" => %{"name" => "In Progress"},
      "comments" => %{
        "nodes" => [
          %{
            "body" => "Claimed by devx work.\n\n- agent: claude\n- machine: imac\n- workspace: `/ws/#{identifier}`\n\ndevx-claim: #{@claim_id}",
            "createdAt" => "2026-11-25T11:00:00Z"
          }
        ]
      }
    }
  end

  defp page(nodes, next_cursor \\ nil) do
    {:ok,
     %{
       "data" => %{
         "issues" => %{
           "nodes" => nodes,
           "pageInfo" => %{"hasNextPage" => next_cursor != nil, "endCursor" => next_cursor}
         }
       }
     }}
  end

  defp start_poller(fleet, responder) do
    {:ok, responses} = Agent.start_link(fn -> responder end)
    name = Module.concat(__MODULE__, "Poller#{System.unique_integer([:positive])}")

    pid =
      start_supervised!(
        {Poller, name: name, settings_fun: fn -> {fleet, nil} end, graphql_fun: fn query, variables -> Agent.get(responses, & &1).(query, variables) end, clock: fn -> @now end},
        id: name
      )

    {name, pid, responses}
  end

  defp eventually(fun, attempts \\ 40)
  defp eventually(_fun, 0), do: flunk("condition not met in time")

  defp eventually(fun, attempts) do
    case fun.() do
      falsy when falsy in [nil, false] ->
        Process.sleep(25)
        eventually(fun, attempts - 1)

      value ->
        value
    end
  end

  test "issue filters follow the fleet settings" do
    assert Poller.issue_filter(nil, nil) == nil
    assert Poller.issue_filter(%Schema.Fleet{}, %{project_slug: "slug"}) == nil

    assert Poller.issue_filter(%Schema.Fleet{team: "PAY"}, nil) == %{
             "team" => %{"key" => %{"eq" => "PAY"}},
             "state" => @in_progress
           }

    assert Poller.issue_filter(%Schema.Fleet{team: "PAY", projects: ["AGS"], states: ["Doing"]}, nil) == %{
             "team" => %{"key" => %{"eq" => "PAY"}},
             "project" => %{"name" => %{"in" => ["AGS"]}},
             "state" => %{"name" => %{"in" => ["Doing"]}}
           }

    assert Poller.issue_filter(%Schema.Fleet{enabled: true}, %{project_slug: "slug"}) == %{
             "project" => %{"slugId" => %{"eq" => "slug"}},
             "state" => @in_progress
           }

    assert Poller.issue_filter(%Schema.Fleet{enabled: true}, %{project_slug: nil}) == nil
    assert Poller.issue_filter(%Schema.Fleet{enabled: true}, nil) == nil
  end

  test "fetch_issues pages through Linear and reports errors" do
    filter = %{"team" => %{"key" => %{"eq" => "PAY"}}}

    two_pages = fn query, variables ->
      assert query =~ "devx-"
      assert %{"filter" => ^filter, "first" => 25} = variables

      case variables["after"] do
        nil -> page([claimed_issue("PAY-1")], "cursor-1")
        "cursor-1" -> page([claimed_issue("PAY-2")])
      end
    end

    assert {:ok, [%{"identifier" => "PAY-1"}, %{"identifier" => "PAY-2"}]} = Poller.fetch_issues(filter, two_pages)

    assert {:ok, issues} = Poller.fetch_issues(filter, fn _query, _variables -> page([claimed_issue("PAY-3")], "again") end)
    assert length(issues) == 8

    assert {:error, {:linear_graphql_errors, [%{"message" => "too complex"}]}} =
             Poller.fetch_issues(filter, fn _q, _v -> {:ok, %{"errors" => [%{"message" => "too complex"}]}} end)

    assert {:error, :linear_unexpected_response} = Poller.fetch_issues(filter, fn _q, _v -> {:ok, %{"data" => nil}} end)
    assert {:error, :timeout} = Poller.fetch_issues(filter, fn _q, _v -> {:error, :timeout} end)
  end

  test "the poller publishes devx agents and keeps them through Linear failures" do
    :ok = SymphonyElixirWeb.ObservabilityPubSub.subscribe()
    fleet = %Schema.Fleet{team: "PAY", interval_ms: 5_000}
    {name, pid, responses} = start_poller(fleet, fn _q, _v -> page([claimed_issue("PAY-1")]) end)

    snapshot = eventually(fn -> match?(%{agents: [_]}, Poller.snapshot(name)) && Poller.snapshot(name) end)

    assert %{enabled: true, error: nil, fetched_at: "2026-11-25T12:00:00Z", agents: [agent]} = snapshot
    assert %{agent: "claude", machine: "imac", issue_identifier: "PAY-1", status: "active", workspace: "/ws/PAY-1"} = agent
    assert_receive :observability_updated

    Agent.update(responses, fn _ -> fn _q, _v -> {:ok, %{"errors" => [%{"message" => "rate limited"}]}} end end)
    send(pid, :poll)
    failed = eventually(fn -> Poller.snapshot(name).error && Poller.snapshot(name) end)
    assert %{error: "Linear: rate limited", agents: [%{issue_identifier: "PAY-1"}]} = failed

    Agent.update(responses, fn _ -> fn _q, _v -> {:error, :econnrefused} end end)
    send(pid, :poll)
    assert eventually(fn -> Poller.snapshot(name).error == ":econnrefused" end)

    Agent.update(responses, fn _ -> fn _q, _v -> raise "boom" end end)
    send(pid, :poll)
    assert eventually(fn -> Poller.snapshot(name).error == ~s({:fleet_poll_crashed, "boom"}) end)
    assert Process.alive?(pid)

    send(pid, :unrelated_message)
    assert %{enabled: true} = Poller.snapshot(name)
  end

  test "a disabled or missing poller reports an empty, disabled fleet" do
    {name, _pid, _responses} = start_poller(%Schema.Fleet{}, fn _q, _v -> flunk("disabled fleets do not query Linear") end)
    assert eventually(fn -> Poller.snapshot(name) == %{enabled: false, agents: [], fetched_at: nil, error: nil} end)

    assert Poller.snapshot(Module.concat(__MODULE__, :Missing)) == %{enabled: false, agents: [], fetched_at: nil, error: nil}
  end

  test "workflow settings feed the poller, and a broken workflow turns it off" do
    {:ok, settings} = Config.settings()
    assert {%Schema.Fleet{enabled: false, team: nil}, _tracker} = Poller.fleet_settings({:ok, settings})
    assert Poller.fleet_settings({:error, :missing_workflow_file}) == {nil, nil}

    name = Module.concat(__MODULE__, :DefaultSettings)
    start_supervised!({Poller, name: name}, id: name)
    assert eventually(fn -> Poller.snapshot(name).enabled == false end)
  end

  test "workflow fleet blocks are parsed and validated" do
    assert {:ok, %{fleet: %Schema.Fleet{team: "PAY", projects: ["AGS · Engagement"], claim_ttl_minutes: 90, interval_ms: 60_000}}} =
             Schema.parse(%{"fleet" => %{"team" => "PAY", "projects" => ["AGS · Engagement"], "claim_ttl_minutes" => 90}})

    assert {:error, {:invalid_workflow_config, message}} = Schema.parse(%{"fleet" => %{"interval_ms" => 10}})
    assert message =~ "interval_ms"
  end
end
