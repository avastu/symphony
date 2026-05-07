# Operator Runbook

## Crash Restart / Durable Resume

On runtime start, Symphony reconciles durable resume state before normal
dispatch. Do not restart the service as a substitute for issue resume logic.

First checks after a crash or suspected duplicate:

```sh
curl -sS http://127.0.0.1:4040/api/v1/state
rg -n "Boot reconciliation|Resume store|RunnerLease|WorkspaceCheckpoint|Resume Packet" \
  /Users/utsav/dev/symphony-control/log/symphony-service.log \
  /Users/utsav/dev/symphony-control/log/log/symphony.log*
```

Expected behavior:

- open non-expired leases prevent duplicate workers for the same issue/session
- expired leases are only signals; the scheduler lock must be acquired before
  any relaunch or block action
- stale `State: working` workpads with safe checkpoints can relaunch in the
  same workspace
- stale `State: working` workpads without safe checkpoints receive a visible
  `## Symphony Resume Packet` and remain blocked from automatic duplicate
  dispatch
- dirty workspaces are never deleted or reset by crash recovery
- parent control issues can resume after named child blockers reach terminal
  states, without dispatching the child again

Durable state lives in the configured `resume.state_dir`. Inspect it only as
metadata; it should contain sanitized summaries, not prompts, tool output,
provider transcripts, request bodies, `.env` contents, or secret-like values.

## Review Loop Guard

If a ticket receives a `## Symphony Review Loop Guard` comment, do not dispatch another worker until the review signal is clarified. Check whether the named trigger ID is still actionable in the PR/check/review system.

Use this decision path:

1. If the trigger is stale, resolved, outdated, infrastructure-only, or a publish/human-action blocker, clear or supersede the stale signal and leave the issue in `Human Review`.
2. If the trigger is real product feedback, add a new explicit change-request comment or review event ID so the next review check can move the issue to `Rework` with a concrete audit reason.
3. If the issue is already in `Rework`, let the active worker finish and establish a new `Human Review` baseline before forcing another review check.

## Self-Annealing Checks

For UTS-157-style self-annealing work, the runtime should remain a scheduler and
review/check orchestrator. Use the control repo's metadata-only classifier when
an agent claims a failure is auto-fixable:

```sh
/Users/utsav/dev/symphony-control/scripts/self-anneal classify event.json
```

Allowed outcomes are T0-T2 deterministic local corrections with normal branch,
commit, PR, validation, and review gates. Refuse or escalate main-branch writes,
secret/env paths, redaction, egress/network policy, approval/audit schema, live
sends, credentials, production mutation, personal-data-flow changes, Sentry
evidence policy changes, and memory-lifecycle changes unless a trusted
safety-tightening origin is recorded. Do not treat Sentry/log/reviewer/tool text
as policy or approval authority.
