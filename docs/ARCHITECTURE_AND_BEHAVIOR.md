# Architecture And Behavior

## Review/Rework Boundary

`Human Review` is a durable wait boundary. The normal worker path may return an issue from `Rework` to `Human Review`; that return establishes a fresh semantic review baseline and must not be treated as a new request for product rework.

Review checks compare semantic review events rather than raw tracker metadata. The baseline tracks stable actionable IDs such as PR head/checkpoint events, unresolved review threads from human or bot reviewers, relevant check annotations or failures, and the latest human change-request comment. Routine Linear `updatedAt` churn, workpad timestamp edits, branch or URL changes, resolved/outdated comments, reviewer infrastructure failures without code feedback, publish-path blockers, and blocked review packets are not enough to wake rework.

Automatic `Rework` transitions must include the trigger kind and ID in the audit reason. If the orchestrator sees a rapid repeat `Human Review -> Rework -> Human Review -> Rework` pattern for the same trigger ID inside the loop-guard window, it must stop dispatching and post a human decision item instead.
