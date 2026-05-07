defmodule SymphonyElixir.ResumeReconcilerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Resume.Reconciler

  @now ~U[2026-05-07 08:00:00Z]
  @old ~U[2026-05-07 07:30:00Z]

  test "crash after workpad blocks when no durable boundary exists" do
    issue = working_issue("issue-after-workpad")

    assert {:block, packet} = Reconciler.boot_action(issue, base_context())
    assert packet.reason == "stale_working_without_safe_checkpoint"
    assert packet.resume_instruction =~ "Review the workspace manually"
  end

  test "crash after branch relaunches from latest safe checkpoint and preserves dirty summary" do
    issue = working_issue("issue-after-branch")

    checkpoint = %{
      "checkpoint_id" => "checkpoint-branch",
      "safe_to_resume" => true,
      "phase_boundary" => "after_branch",
      "routed_repos" => [%{"repo" => "Symphony", "branch" => "uts-159", "dirty" => true}]
    }

    context = Map.put(base_context(), :latest_checkpoints, %{"issue-after-branch" => checkpoint})

    assert {:relaunch, ^checkpoint} = Reconciler.boot_action(issue, context)
    assert hd(checkpoint["routed_repos"])["dirty"] == true
  end

  test "crash before PR blocks non-idempotent retries without a safe boundary" do
    issue = working_issue("issue-before-pr")

    checkpoint = %{
      "checkpoint_id" => "checkpoint-before-pr",
      "safe_to_resume" => true,
      "phase_boundary" => "before_pr",
      "non_idempotent_retry_requires_review" => true
    }

    context = Map.put(base_context(), :latest_checkpoints, %{"issue-before-pr" => checkpoint})

    assert {:block, packet} = Reconciler.boot_action(issue, context)
    assert packet.reason == "stale_working_without_safe_checkpoint"
  end

  test "crash during review remains parked" do
    issue = %Issue{
      id: "issue-review",
      identifier: "UTS-159",
      title: "Review",
      state: "Human Review",
      workpad_state: "ready_for_review",
      updated_at: @old
    }

    assert :park_review = Reconciler.boot_action(issue, base_context())
  end

  test "active leases suppress duplicate stale-working relaunch" do
    issue = working_issue("issue-active-lease")

    context =
      base_context()
      |> Map.put(:active_lease_issue_ids, MapSet.new(["issue-active-lease"]))

    assert :ignore = Reconciler.boot_action(issue, context)
  end

  test "parent UTS-99 gate resumes when child blocker is done or merged" do
    done_parent = parent_issue("Done")
    merged_parent = parent_issue("Merged")

    assert {:resume_parent, done_packet} = Reconciler.boot_action(done_parent, base_context())
    assert done_packet.reason == "child_gate_cleared"

    assert {:resume_parent, merged_packet} = Reconciler.boot_action(merged_parent, base_context())
    assert merged_packet.reason == "child_gate_cleared"
  end

  defp working_issue(issue_id) do
    %Issue{
      id: issue_id,
      identifier: "UTS-159",
      title: "Crash restart",
      state: "Rework",
      workpad_state: "working",
      updated_at: @old
    }
  end

  defp parent_issue(blocker_state) do
    %Issue{
      id: "issue-uts-99-#{blocker_state}",
      identifier: "UTS-99",
      title: "Project control",
      state: "Human Review",
      workpad_state: "blocked",
      blocked_by: [%{id: "child", identifier: "UTS-159", state: blocker_state}],
      updated_at: @old
    }
  end

  defp base_context do
    %{
      now: @now,
      stale_interval_ms: 10 * 60 * 1_000,
      running_issue_ids: MapSet.new(),
      active_lease_issue_ids: MapSet.new(),
      latest_checkpoints: %{},
      terminal_states: MapSet.new(["done", "closed", "canceled", "cancelled", "duplicate", "merged"])
    }
  end
end
