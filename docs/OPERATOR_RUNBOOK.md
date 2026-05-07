# Operator Runbook

## Review Loop Guard

If a ticket receives a `## Symphony Review Loop Guard` comment, do not dispatch another worker until the review signal is clarified. Check whether the named trigger ID is still actionable in the PR/check/review system.

Use this decision path:

1. If the trigger is stale, resolved, outdated, infrastructure-only, or a publish/human-action blocker, clear or supersede the stale signal and leave the issue in `Human Review`.
2. If the trigger is real product feedback, add a new explicit change-request comment or review event ID so the next review check can move the issue to `Rework` with a concrete audit reason.
3. If the issue is already in `Rework`, let the active worker finish and establish a new `Human Review` baseline before forcing another review check.
