defmodule SymphonyElixir.AttentionInboxTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.AttentionInbox

  test "refresh caches prioritized attention items and extracts deployment links" do
    fetch_counter = start_supervised!({Agent, fn -> 0 end})

    fetch_fun = fn ->
      Agent.update(fetch_counter, &(&1 + 1))

      {:ok,
       Jason.encode!([
         %{
           "identifier" => "UTS-2",
           "title" => "FYI item",
           "url" => "https://linear.app/utsav/issue/UTS-2/fyi",
           "linear_state" => "In Progress",
           "project" => "Symphony",
           "classification" => "fyi",
           "reason" => "No action.",
           "next_action" => "No immediate action.",
           "excerpt" => ""
         },
         %{
           "identifier" => "UTS-1",
           "title" => "Review thisprecious.life",
           "url" => "https://linear.app/utsav/issue/UTS-1/review",
           "linear_state" => "Human Review",
           "project" => "Beta Launch Validation",
           "classification" => "ready_for_review",
           "reason" => "Issue is ready for human review.",
           "next_action" => "Review the linked artifacts.",
           "excerpt" => "Preview available in uploaded artifacts.",
           "links" => [
             %{
               "url" => "https://tpl-git-fix-avastu.vercel.app",
               "host" => "tpl-git-fix-avastu.vercel.app",
               "kind" => "vercel",
               "label" => "Vercel deployment"
             }
           ]
         }
       ])}
    end

    server = Module.concat(__MODULE__, :PrioritizedInbox)

    start_supervised!({AttentionInbox, name: server, fetch_fun: fetch_fun, reply_fun: fn _, _ -> :ok end, auto_refresh: false})

    assert AttentionInbox.snapshot(server).status == "loading"
    assert {:ok, snapshot} = AttentionInbox.refresh(server)

    assert Agent.get(fetch_counter, & &1) == 1
    assert Enum.map(snapshot.items, & &1.identifier) == ["UTS-1", "UTS-2"]
    assert [%{label: "Vercel deployment", kind: "vercel"}] = hd(snapshot.items).deployment_links
    assert snapshot.counts == %{"fyi" => 1, "ready_for_review" => 1}

    assert AttentionInbox.snapshot(server).items |> length() == 2
    assert Agent.get(fetch_counter, & &1) == 1
  end

  test "priority favors routing fixes before general review work" do
    fetch_fun = fn ->
      {:ok,
       Jason.encode!([
         %{
           "identifier" => "UTS-20",
           "title" => "Review artifact",
           "url" => "https://linear.app/utsav/issue/UTS-20/review-artifact",
           "linear_state" => "Human Review",
           "project" => "Symphony",
           "classification" => "ready_for_review",
           "reason" => "Issue is ready for human review.",
           "next_action" => "Review the linked artifacts.",
           "excerpt" => ""
         },
         %{
           "identifier" => "UTS-10",
           "title" => "Needs repo routing",
           "url" => "https://linear.app/utsav/issue/UTS-10/needs-repo-routing",
           "linear_state" => "In Review",
           "project" => "Symphony",
           "classification" => "needs_decision",
           "reason" => "Decision Needed: Add a `Repos:` section to the issue body, then reply `Retry`.",
           "next_action" => "Answer the decision request.",
           "excerpt" => "Retry"
         }
       ])}
    end

    server = Module.concat(__MODULE__, :RoutingFirstInbox)

    start_supervised!({AttentionInbox, name: server, fetch_fun: fetch_fun, reply_fun: fn _, _ -> :ok end, auto_refresh: false})

    assert {:ok, snapshot} = AttentionInbox.refresh(server)
    assert Enum.map(snapshot.items, & &1.identifier) == ["UTS-10", "UTS-20"]

    assert %{
             priority_rank: 0,
             priority_label: "P0 Route",
             priority_reason: "Small routing fix unlocks Symphony dispatch.",
             action_family: "routing",
             action_label: "Add repo routing"
           } = hd(snapshot.items)
  end

  test "approve and deny post guarded reply commands then refresh the cache" do
    reply_agent = start_supervised!({Agent, fn -> [] end})

    fetch_fun = fn ->
      {:ok,
       Jason.encode!([
         %{
           "identifier" => "UTS-9",
           "title" => "Needs decision",
           "url" => "https://linear.app/utsav/issue/UTS-9/needs-decision",
           "linear_state" => "Human Review",
           "project" => "Symphony",
           "classification" => "needs_decision",
           "reason" => "Decision Needed: approve the plan",
           "next_action" => "Answer the decision request.",
           "excerpt" => ""
         }
       ])}
    end

    reply_fun = fn issue, body ->
      Agent.update(reply_agent, &(&1 ++ [{issue, body}]))
      :ok
    end

    server = Module.concat(__MODULE__, :ActionInbox)

    start_supervised!({AttentionInbox, name: server, fetch_fun: fetch_fun, reply_fun: reply_fun, auto_refresh: false})

    assert {:ok, _snapshot} = AttentionInbox.act(server, "UTS-9", :approve)
    assert {:ok, _snapshot} = AttentionInbox.act(server, "UTS-9", :deny, note: "ship with screenshots")

    assert Agent.get(reply_agent, & &1) == [
             {"UTS-9", "Approved."},
             {"UTS-9", "Revise plan: ship with screenshots"}
           ]
  end
end
