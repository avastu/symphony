defmodule SymphonyElixir.ReviewLoopSafeguardsTest do
  use SymphonyElixir.TestSupport

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    :ok
  end

  test "end-to-end review loop uses a new semantic event before dispatching rework again" do
    issue = review_issue("issue-cycle")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    assert {:reply, quiet_payload, quiet_state} =
             Orchestrator.handle_call({:request_review_check, issue.id}, {self(), make_ref()}, review_state(issue.id))

    assert quiet_payload.reason == "review_checkpoint_unchanged"
    assert quiet_payload.queued == false

    review_thread = %{id: "review_thread:codex-thread-1", kind: "codex_review"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [%{issue | review_events: [review_thread]}])

    assert {:reply, rework_payload, rework_state} =
             Orchestrator.handle_call(
               {:request_review_check, issue.id},
               {self(), make_ref()},
               claim(quiet_state, issue.id)
             )

    assert rework_payload.queued == true
    assert rework_payload.reason == "review_trigger_rework:codex_review:review_thread:codex-thread-1"
    assert rework_payload.review_trigger_id == "review_thread:codex-thread-1"
    assert_receive {:memory_tracker_state_update, "issue-cycle", "Rework"}

    resolved_issue = %{
      issue
      | updated_at: ~U[2026-05-07 01:00:00Z],
        review_events: [
          Map.put(review_thread, :outdated, true),
          %{id: "pr_head:sha-resolution", kind: "pr_head", sha: "sha-resolution", actionable: false}
        ]
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [resolved_issue])

    assert {:reply, returned_payload, returned_state} =
             Orchestrator.handle_call(
               {:request_review_check, issue.id},
               {self(), make_ref()},
               claim(rework_state, issue.id)
             )

    assert returned_payload.reason == "review_checkpoint_unchanged"
    assert returned_payload.queued == false
    refute_receive {:memory_tracker_state_update, "issue-cycle", "Rework"}, 50

    assert {:reply, still_quiet_payload, still_quiet_state} =
             Orchestrator.handle_call(
               {:request_review_check, issue.id},
               {self(), make_ref()},
               claim(returned_state, issue.id)
             )

    assert still_quiet_payload.reason == "review_checkpoint_unchanged"
    assert still_quiet_payload.queued == false

    new_thread = %{id: "review_thread:copilot-thread-2", kind: "copilot_review"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [%{resolved_issue | review_events: [new_thread]}])

    assert {:reply, new_feedback_payload, _state} =
             Orchestrator.handle_call(
               {:request_review_check, issue.id},
               {self(), make_ref()},
               claim(still_quiet_state, issue.id)
             )

    assert new_feedback_payload.queued == true
    assert new_feedback_payload.reason == "review_trigger_rework:copilot_review:review_thread:copilot-thread-2"
    assert_receive {:memory_tracker_state_update, "issue-cycle", "Rework"}
  end

  test "positive review trigger matrix names the concrete event in the audit reason" do
    cases = [
      {%{id: "review_thread:thread-1", kind: "review_thread"}, "review_thread"},
      {%{id: "check_annotation:ann-1", kind: "check_annotation"}, "check_annotation"},
      {%{id: "check_failure:run-1", kind: "check_failure", conclusion: "failure"}, "check_failure"},
      {%{id: "human_change_request:comment-1", kind: "human_change_request"}, "human_change_request"},
      {%{id: "pr_head:sha-new", kind: "pr_head", sha: "sha-new"}, "pr_head"}
    ]

    for {event, expected_kind} <- cases do
      issue = review_issue("issue-#{expected_kind}", review_events: [event])
      issue_id = issue.id
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      assert {:reply, payload, _state} =
               Orchestrator.handle_call(
                 {:request_review_check, issue.id},
                 {self(), make_ref()},
                 review_state(issue.id)
               )

      assert payload.queued == true
      assert payload.review_trigger_id == event.id
      assert payload.review_trigger_kind == expected_kind
      assert payload.reason == "review_trigger_rework:#{expected_kind}:#{event.id}"
      assert_receive {:memory_tracker_state_update, ^issue_id, "Rework"}
    end
  end

  test "noise events and routine Linear/workpad timestamp changes stay parked in review" do
    cases = [
      %{id: "review_thread:old-thread", kind: "review_thread", outdated: true},
      %{id: "check_failure:infra-red", kind: "check_failure", infrastructure_failure: true},
      %{id: "human_change_request:publish-blocker", kind: "human_change_request", requires_human: true},
      %{id: "review_thread:resolved-thread", kind: "review_thread", resolved: true}
    ]

    for event <- cases do
      issue =
        review_issue("noise-#{event.id}",
          updated_at: ~U[2026-05-07 01:15:00Z],
          workpad_state: "ready_for_review",
          review_events: [event]
        )

      issue_id = issue.id
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      assert {:reply, payload, _state} =
               Orchestrator.handle_call(
                 {:request_review_check, issue.id},
                 {self(), make_ref()},
                 review_state(issue.id, workpad_state: "ready_for_review", updated_at: ~U[2026-05-07 01:00:00Z])
               )

      assert payload.queued == false
      assert payload.reason == "ready_review_boundary"
      refute_receive {:memory_tracker_state_update, ^issue_id, "Rework"}, 50
    end
  end

  test "loop guard surfaces a human decision instead of redispatching the same recent event" do
    issue = review_issue("issue-loop-guard", review_events: [%{id: "review_thread:stale", kind: "review_thread"}])
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

    state =
      review_state(issue.id,
        review_rework_triggers: %{
          issue.id => %{trigger_id: "review_thread:stale", triggered_at_ms: System.monotonic_time(:millisecond)}
        }
      )

    assert {:reply, payload, updated_state} =
             Orchestrator.handle_call({:request_review_check, issue.id}, {self(), make_ref()}, state)

    assert payload.queued == false
    assert payload.reason == "review_loop_guard_human_decision:review_thread:review_thread:stale"
    assert payload.operations == ["review_check", "loop_guard", "human_decision", "trigger:review_thread:stale"]
    refute MapSet.member?(updated_state.claimed, issue.id)
    refute_receive {:memory_tracker_state_update, "issue-loop-guard", "Rework"}, 50
    assert_receive {:memory_tracker_comment, "issue-loop-guard", body}
    assert body =~ "## Symphony Review Loop Guard"
    assert body =~ "review_thread:stale"
  end

  defp review_issue(id, attrs \\ []) do
    attrs = Map.new(attrs)

    %Issue{
      id: id,
      identifier: String.upcase(String.replace(id, "_", "-")),
      title: "Review-loop fixture",
      state: Map.get(attrs, :state, "Human Review"),
      workpad_state: Map.get(attrs, :workpad_state),
      review_action: Map.get(attrs, :review_action),
      review_events: Map.get(attrs, :review_events, []),
      updated_at: Map.get(attrs, :updated_at, ~U[2026-05-07 00:00:00Z]),
      branch_name: "uts-136-review-loop",
      url: "https://linear.app/issue/#{id}"
    }
  end

  defp review_state(issue_id, attrs \\ []) do
    attrs = Map.new(attrs)
    workpad_state = Map.get(attrs, :workpad_state)

    %Orchestrator.State{
      poll_interval_ms: 30_000,
      max_concurrent_agents: 1,
      claimed: MapSet.new([issue_id]),
      review_checkpoints:
        Map.get(attrs, :review_checkpoints, %{
          issue_id => %{
            state: "Human Review",
            workpad_state: workpad_state,
            review_baseline: %{actionable_event_ids: [], events: []}
          }
        }),
      review_rework_triggers: Map.get(attrs, :review_rework_triggers, %{}),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      codex_rate_limits: nil
    }
  end

  defp claim(%Orchestrator.State{} = state, issue_id), do: %{state | claimed: MapSet.new([issue_id])}
end
