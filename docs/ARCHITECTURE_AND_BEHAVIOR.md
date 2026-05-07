# Architecture And Behavior

## Durable Resume Spine

Runtime dispatch now has a file-backed resume spine. The scheduler writes
sanitized `IssueRun`, `RunnerLease`, `WorkspaceCheckpoint`, scheduler lock, and
resume-packet records before and during worker execution. These records are
coordination metadata only: they must not contain raw Codex prompts, raw tool
output, provider transcripts, request bodies, `.env` values, secret-like values,
or unbounded private Linear payloads.

A runner lease is a duplicate guard, not permission to relaunch. Workers
heartbeat active leases while they run. If a lease expires, normal dispatch must
still treat the open lease as owned until startup/retry reconciliation acquires
the scheduler lock, refreshes current Linear/workpad state, verifies no active
runner owns the issue, and closes the stale lease.

Startup reconciliation runs before normal dispatch. Its order is:

1. Acquire the scheduler lock.
2. Respect deploy-pending intent and keep dispatch closed while deploy is
   pending, draining, deploying, or failed.
3. Verify runtime/workflow/deploy-intent paths and runtime commit metadata.
4. Expire stale leases and hydrate the latest persisted checkpoints.
5. Fetch active and review Linear issues and workpad fields.
6. Relaunch stale `State: working` issues only from a safe checkpoint.
7. Write a visible blocked resume packet when no safe checkpoint exists or a
   retry would be non-idempotent.
8. Resume parent control issues whose specific child blockers are terminal,
   without starting duplicate child work.
9. Release the lock, then let the normal dispatch loop proceed.

Workspace cleanup is not a crash-recovery mechanism. Dirty or existing
workspaces are preserved; resume packets and checkpoints describe the workspace
state so a later worker or human can continue in place.

## Review/Rework Boundary

`Human Review` is a durable wait boundary. The normal worker path may return an issue from `Rework` to `Human Review`; that return establishes a fresh semantic review baseline and must not be treated as a new request for product rework.

Review checks compare semantic review events rather than raw tracker metadata. The baseline tracks stable actionable IDs such as PR head/checkpoint events, unresolved review threads from human or bot reviewers, relevant check annotations or failures, and the latest human change-request comment after the current workpad handoff. The workpad handoff scopes Linear comment commands: older `Revise plan:`, `Approved with change:`, `Answer:`, or `Retry` comments belong to earlier packets and must not wake new rework. Generated Symphony comments, including `## Codex Workpad`, `## Symphony Uploaded Artifacts`, and `## Symphony Review Loop Guard`, are not review feedback sources. Routine Linear `updatedAt` churn, workpad timestamp edits, branch or URL changes, resolved/outdated comments, reviewer infrastructure failures without code feedback, publish-path blockers, and blocked review packets are not enough to wake rework.

Automatic `Rework` transitions must include the trigger kind and ID in the audit reason. If the orchestrator sees a rapid repeat `Human Review -> Rework -> Human Review -> Rework` pattern for the same trigger ID inside the loop-guard window, it must stop dispatching and post a human decision item instead.

## Self-Annealing Boundary

Self-annealing is workflow-mediated correction for bounded deterministic
implementation, test, and reviewer failures. The Elixir scheduler does not
perform production mutation, live sends, deploys, Sentry resolves, secret
rotation, auto-merge, or approval weakening for M0.

The metadata observer lives in the control-plane repo as `scripts/self-anneal`.
It classifies T0-T2 auto-fix eligibility, refuses main-branch and secret/env
file touches, escalates protected safety surfaces unless trusted
safety-tightening is proven, and renders honest PR/workpad evidence. Runtime
review checks may use the resulting workpad/PR evidence, but the observer
output is not a substitute for Linear state, human gates, validation, PR checks,
or high-tier review.
