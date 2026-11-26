defmodule SymphonyElixir.FleetTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Fleet

  @now ~U[2026-11-25 12:00:00Z]
  @claim_a "11111111-1111-4111-8111-111111111111"
  @claim_b "22222222-2222-4222-8222-222222222222"
  @claim_c "33333333-3333-4333-8333-333333333333"

  defp claim_body(claim_id, agent, machine, workspace) do
    Enum.join(
      [
        "Claimed by devx work.",
        "",
        "- agent: #{agent}",
        "- machine: #{machine}",
        "- workspace: `#{workspace}`",
        "- claimed: 2026-11-25 10:00 UTC",
        "",
        "devx-claim: #{claim_id}"
      ],
      "\n"
    )
  end

  defp heartbeat_body(claim_id, message, agent, machine, kind \\ "heartbeat") do
    "#{message}\n\n_#{agent} on #{machine}_\n\ndevx-#{kind}: #{claim_id}"
  end

  defp issue(identifier, comments) do
    %{
      "identifier" => identifier,
      "title" => "Title of #{identifier}",
      "url" => "https://linear.app/payonce/issue/#{identifier}",
      "state" => %{"name" => "In Progress"},
      "comments" => %{"nodes" => comments}
    }
  end

  defp comment(body, at), do: %{"body" => body, "createdAt" => at}

  test "an active devx claim carries agent, machine, workspace and the latest checkpoint" do
    issues = [
      issue("PAY-1", [
        # Out of order on purpose: Linear's createdAt decides.
        comment(heartbeat_body(@claim_a, "Tests pass; opening a PR.", "claude", "imac"), "2026-11-25T11:30:00.000Z"),
        comment(claim_body(@claim_a, "claude", "imac", "/Users/m/code/ags/_ws/pay-1"), "2026-11-25T10:00:00.000Z"),
        comment(heartbeat_body(@claim_a, "Reproduced the bug.", "claude", "imac"), "2026-11-25T10:30:00.000Z")
      ])
    ]

    assert [agent] = Fleet.devx_agents(issues, now: @now)

    assert agent == %{
             source: "devx",
             status: "active",
             agent: "claude",
             machine: "imac",
             workspace: "/Users/m/code/ags/_ws/pay-1",
             issue_identifier: "PAY-1",
             issue_url: "https://linear.app/payonce/issue/PAY-1",
             issue_title: "Title of PAY-1",
             state: "In Progress",
             claim_id: @claim_a,
             claimed_at: "2026-11-25T10:00:00Z",
             last_seen_at: "2026-11-25T11:30:00Z",
             last_message: "Tests pass; opening a PR."
           }
  end

  test "released claims disappear, quiet claims go stale, and newest activity sorts first" do
    issues = [
      issue("PAY-2", [
        comment(claim_body(@claim_a, "codex", "codex-cloud-abc", "/workspace/ags"), "2026-11-25T11:00:00Z"),
        comment(claim_body(@claim_b, "pi", "macbook", "/Users/m/code/ags/_ws/pay-2"), "2026-11-25T11:00:01Z"),
        comment("Lost the claim race to an earlier agent; standing down.\n\ndevx-release: #{@claim_b}", "2026-11-25T11:00:05Z")
      ]),
      issue("PAY-3", [
        comment(claim_body(@claim_c, "claude", "agent-box", "/home/agent/code/ags/_ws/pay-3"), "2026-11-25T07:00:00Z")
      ])
    ]

    assert [active, stale] = Fleet.devx_agents(issues, now: @now)
    assert %{issue_identifier: "PAY-2", agent: "codex", machine: "codex-cloud-abc", status: "active"} = active
    assert active.last_message == nil
    assert %{issue_identifier: "PAY-3", status: "stale"} = stale

    assert [%{status: "active"}] =
             Fleet.devx_agents([Enum.at(issues, 1)], now: @now, claim_ttl_minutes: 600)
  end

  test "a heartbeat without its claim, a duplicate claim marker and malformed comments are ignored" do
    issues = [
      issue("PAY-4", [
        comment(heartbeat_body(@claim_b, "orphan", "pi", "macbook"), "2026-11-25T11:00:00Z"),
        comment(claim_body(@claim_a, "claude", "imac", "/w"), "2026-11-25T11:10:00Z"),
        comment(claim_body(@claim_a, "codex", "elsewhere", "/x"), "2026-11-25T11:20:00Z"),
        comment(heartbeat_body(@claim_a, "", "claude", "imac"), "2026-11-25T11:40:00Z"),
        comment("devx-heartbeat: #{@claim_a}", "not a time"),
        %{"body" => nil, "createdAt" => "2026-11-25T11:50:00Z"},
        %{}
      ]),
      %{"identifier" => "PAY-5"}
    ]

    assert [agent] = Fleet.devx_agents(issues, now: @now)
    assert %{agent: "claude", machine: "imac", workspace: "/w", last_message: nil} = agent
    assert agent.last_seen_at == "2026-11-25T11:40:00Z"
    assert agent.state == "In Progress"
  end

  test "claim bodies and checkpoint messages parse independently" do
    assert Fleet.parse_claim_body(claim_body(@claim_a, "pi", "mini", "/a b")) ==
             %{agent: "pi", machine: "mini", workspace: "/a b"}

    assert Fleet.parse_claim_body("no fields here") == %{}
    assert Fleet.checkpoint_message(heartbeat_body(@claim_a, "**Done.** PR up", "codex", "imac", "release")) == "**Done.** PR up"
    assert Fleet.checkpoint_message("devx-heartbeat: #{@claim_a}") == nil
    assert Fleet.checkpoint_message("plain note") == "plain note"
  end

  test "symphony sessions take the same shape and merge with devx agents" do
    running = [
      %{
        issue_identifier: "MT-1",
        issue_url: "https://example.org/MT-1",
        state: "In Progress",
        worker_host: nil,
        workspace_path: "/tmp/ws/MT-1",
        session_id: "thread-1",
        started_at: "2026-11-25T11:00:00Z",
        last_event_at: "2026-11-25T11:59:00Z",
        last_message: "editing files"
      }
    ]

    blocked = [
      %{
        issue_identifier: "MT-2",
        issue_url: nil,
        state: "In Progress",
        worker_host: "dm-dev2",
        workspace_path: nil,
        session_id: "thread-2",
        blocked_at: "2026-11-25T09:00:00Z",
        last_event_at: nil,
        last_message: nil,
        error: "needs approval"
      }
    ]

    symphony = Fleet.symphony_agents(running, blocked, "imac")

    assert [
             %{source: "symphony", status: "active", agent: "codex", machine: "imac", claim_id: "thread-1"},
             %{source: "symphony", status: "blocked", machine: "dm-dev2", last_message: "needs approval"}
           ] = symphony

    assert Enum.at(symphony, 1).last_seen_at == "2026-11-25T09:00:00Z"

    devx = Fleet.devx_agents([issue("PAY-1", [comment(claim_body(@claim_a, "pi", "mini", "/w"), "2026-11-25T11:30:00Z")])], now: @now)
    no_time = %{hd(devx) | last_seen_at: nil, issue_identifier: "PAY-9"}

    assert ["MT-1", "PAY-1", "MT-2", "PAY-9"] =
             symphony |> Fleet.merge(devx ++ [no_time]) |> Enum.map(& &1.issue_identifier)
  end

  test "devx_agents defaults the clock and TTL" do
    recent = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.to_iso8601()
    assert [%{status: "active"}] = Fleet.devx_agents([issue("PAY-6", [comment(claim_body(@claim_a, "pi", "m", "/w"), recent)])])
  end
end
