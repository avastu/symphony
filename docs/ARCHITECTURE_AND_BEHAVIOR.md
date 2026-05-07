# Architecture And Behavior

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
