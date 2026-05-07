defmodule SymphonyElixir.ResumeStoreTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Resume.Store

  test "run lease and checkpoint persistence stores sanitized metadata only" do
    secret = "LINEAR_API_KEY=lin_secret Authorization: Bearer provider-secret"

    issue = %Issue{
      id: "issue-secret",
      identifier: "UTS-159",
      title: "Durable resume",
      state: "In Progress",
      workpad_state: "working"
    }

    assert {:ok, %{run: run, lease: lease}} =
             Store.create_run_and_lease(issue,
               worker_host: "worker-a",
               attempt: 2,
               session_key: "issue-secret-session"
             )

    assert run["record_type"] == "IssueRun"
    assert lease["record_type"] == "RunnerLease"
    assert Store.open_lease_for_issue?("issue-secret")
    assert Store.active_lease_for_issue?("issue-secret")

    assert {:ok, checkpoint} =
             Store.put_workspace_checkpoint(%{
               issue_id: "issue-secret",
               identifier: "UTS-159",
               run_id: run["run_id"],
               lease_id: lease["lease_id"],
               phase_boundary: "after_workpad",
               safe_to_resume: true,
               prompt: "raw codex prompt #{secret}",
               tool_output: "raw tool output #{secret}",
               request_body: %{"message" => "private payload #{secret}"},
               metadata: %{
                 summary: "branch exists #{secret}",
                 env: %{"LINEAR_API_KEY" => "lin_secret"}
               }
             })

    assert checkpoint["prompt"] == "[redacted]"
    assert checkpoint["tool_output"] == "[redacted]"
    assert checkpoint["request_body"] == "[redacted]"
    assert checkpoint["metadata"]["env"] == "[redacted]"
    assert checkpoint["metadata"]["summary"] =~ "LINEAR_API_KEY=[redacted]"
    refute inspect(checkpoint) =~ "lin_secret"
    refute inspect(checkpoint) =~ "provider-secret"
  end

  test "expired leases stay duplicate guards until scheduler reconciliation closes them" do
    past =
      DateTime.utc_now()
      |> DateTime.add(-60, :second)
      |> DateTime.to_iso8601()

    assert {:ok, lease} =
             Store.put_runner_lease(%{
               issue_id: "issue-expired",
               identifier: "UTS-159",
               lease_id: "lease-expired",
               run_id: "run-expired",
               status: "active",
               expires_at: past
             })

    assert lease["status"] == "active"
    assert Store.open_lease_for_issue?("issue-expired")
    refute Store.active_lease_for_issue?("issue-expired")

    assert {:ok, [expired]} = Store.expire_stale_leases()
    assert expired["status"] == "expired"
    refute Store.open_lease_for_issue?("issue-expired")
  end

  test "scheduler lock serializes resume decisions" do
    assert {:ok, lock} = Store.acquire_scheduler_lock(60_000, %{phase: "test"})
    assert {:error, :locked} = Store.acquire_scheduler_lock(60_000, %{phase: "test"})
    assert :ok = Store.release_scheduler_lock(lock)
    assert {:ok, second_lock} = Store.acquire_scheduler_lock(60_000, %{phase: "test"})
    assert :ok = Store.release_scheduler_lock(second_lock)
  end

  test "long unicode metadata truncates without breaking persisted JSON" do
    long_unicode = String.duplicate("resume-safe-☸", 120)

    assert {:ok, packet} =
             Store.write_resume_packet(%{
               issue_id: "issue-unicode",
               identifier: "UTS-159",
               status: "blocked",
               reason: long_unicode
             })

    assert packet["reason"] =~ "... [truncated]"
    assert String.valid?(packet["reason"])
    assert [%{"reason" => persisted_reason}] = Store.list_resume_packets()
    assert persisted_reason == packet["reason"]
  end
end
