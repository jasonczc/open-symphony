# GitHub Feedback Surfaces Feature Narrative

## Summary

Open Symphony should treat GitHub as the primary control plane for agent work. Agents should not only create branches and pull requests; they should also leave clear, durable, low-noise feedback in the GitHub surfaces developers already use.

The feature adds a configurable GitHub feedback layer that can publish agent state, delivery summaries, validation results, and follow-up signals to Issues, Pull Requests, commit statuses, checks, reactions, and review comments.

The default experience should stay conservative: one issue workpad, one pull request delivery summary, and structured status signals. More granular comments, such as inline review comments or commit comments, should be available but opt-in.

## Problem

The current GitHub delivery path proves the main automation loop works:

1. Pick up a labeled GitHub issue.
2. Claim it through the issue workpad.
3. Run an agent in an isolated workspace.
4. Push a branch.
5. Open a draft pull request.
6. Record validation and the PR URL.

However, the returned information is minimal. Developers can see that work happened, but they cannot always answer these questions from GitHub alone:

- What exactly did the agent change?
- Why did it choose this approach?
- Which validations ran, and where should I inspect failures?
- Is the agent still working, blocked, waiting for review, or done?
- How do I ask the same agent to continue on this PR?
- Did the agent acknowledge my follow-up comment?
- Which comments are durable orchestration state versus human discussion?

Without a dedicated feedback model, we risk either under-communicating useful agent context or over-communicating noisy comments across issues, PRs, commits, and diffs.

## Goals

- Make agent work understandable from GitHub without opening local logs.
- Keep feedback low-noise and predictable.
- Preserve the issue workpad as the durable orchestration source of truth.
- Add PR-level delivery summaries for human reviewers.
- Support follow-up loops from PR comments and issue comments.
- Represent agent progress with GitHub-native signals where appropriate.
- Avoid leaking raw prompts, hidden reasoning, secrets, workspace paths, or excessive logs.
- Allow advanced feedback surfaces to be enabled per workflow.

## Non-Goals

- Uploading full model transcripts by default.
- Publishing hidden chain-of-thought or private reasoning.
- Replacing GitHub Actions checks.
- Automatically approving or merging pull requests.
- Posting comments on every commit by default.
- Turning GitHub into a high-volume agent log stream.

## Design Principle

Prefer the least noisy GitHub surface that still communicates the state clearly.

Recommended hierarchy:

1. Machine-readable state in issue workpad metadata.
2. Human-readable delivery summary in PR body or sticky PR comment.
3. Lightweight acknowledgement through reactions.
4. Structured pass/fail through commit status or check runs.
5. Inline review comments only for reviewer agents.
6. Commit comments only for explicit opt-in diagnostic workflows.

## Feedback Surfaces

### 1. Issue Workpad

The issue workpad remains the canonical orchestration record.

It should contain:

- Current status.
- Current claim.
- Branch name.
- PR URL.
- Validation commands and pass/fail state.
- Last delivery time.
- Recent high-level events.
- Machine-readable Open Symphony marker.

The workpad should be updated in place instead of posting new progress comments.

Recommended default: enabled.

### 2. Pull Request Body

The PR body should describe the delivered change for reviewers.

It should contain:

- Linked issue.
- Short summary of what changed.
- Validation results.
- Known risks or blockers.
- Branch name.
- Agent identity and run ID, if safe.

The PR body is good for stable delivery information, but it is not ideal for iterative status updates after every follow-up. For iterative updates, use a sticky PR comment.

Recommended default: enabled.

### 3. Sticky PR Comment

A sticky PR comment is a single Open Symphony comment on the PR conversation that gets updated across runs.

It should contain:

- Current agent status.
- Latest run summary.
- Latest validation result.
- Last commit SHA.
- Follow-up instructions.
- Link back to the issue workpad.

Example:

```md
## Open Symphony Delivery

**Status:** ready_for_review
**Agent:** codex
**Issue:** GH-123
**Branch:** `open-symphony/123-fix-parser`
**Commit:** `abc1234`

### What changed
- Added parser handling for escaped delimiters.
- Added regression tests for nested escaped input.

### Validation
- ✅ `mix compile --warnings-as-errors`
- ✅ `mix test test/parser_test.exs`

### Review notes
- The change is limited to parser normalization and tests.
- No migration or runtime configuration changes.

To request changes, comment with `@open-symphony ...` or `@os ...` on this PR.
```

Recommended default: enabled after MVP.

### 4. Trigger Comment Reactions

When a user comment triggers a run, Open Symphony should acknowledge it with a reaction.

Suggested reactions:

- `eyes` when the comment is accepted and work starts.
- `rocket` when work is dispatched.
- `confused` or a reply comment when the command cannot be accepted.

This mirrors the lightweight acknowledgement pattern used by GitHub-native agents and avoids an extra comment for every accepted command.

Recommended default: enabled.

### 5. Commit Status

Open Symphony can create commit statuses on the PR head SHA.

Suggested contexts:

- `open-symphony/agent`
- `open-symphony/validation`

Suggested states:

- `pending` when a run starts.
- `success` when delivery or validation succeeds.
- `failure` when validation fails.
- `error` when orchestration fails before validation.

Commit status gives reviewers a GitHub-native pass/fail signal without adding comment noise.

Recommended default: enabled when token permissions allow it.

### 6. Check Run

Check runs can provide richer output than commit statuses, including summaries and annotations.

Use check runs when:

- The installation is a GitHub App with Checks permission.
- Validation output needs a structured summary.
- A reviewer should see grouped agent/validation details in the Checks tab.

Check runs should not duplicate GitHub Actions. They should summarize Open Symphony's own agent and validation lifecycle.

Recommended default: disabled for personal-token MVP, enabled for GitHub App deployments.

### 7. PR Review and Inline Comments

Inline comments should be used by reviewer agents, not implementation agents.

Use cases:

- A reviewer agent finds a concrete bug on a changed line.
- A security reviewer points to a risky diff hunk.
- A test reviewer suggests a missing assertion.

Inline comments should be batched into a single review when possible. They should avoid stale comments by anchoring to the latest head SHA and avoiding comments on already-resolved code.

Recommended default: disabled until reviewer-agent mode exists.

### 8. Commit Comments

GitHub supports comments directly on commits, but Open Symphony should not use them by default.

Reasons:

- They are easy to miss in normal PR review flow.
- They become stale when commits are amended or rebased.
- They fragment the agent narrative across commits.
- They create unnecessary noise for simple delivery runs.

Commit comments can still be useful for advanced traceability, such as explaining generated sub-commits in a multi-agent pipeline. This should be opt-in.

Recommended default: disabled.

## Configuration

Proposed workflow configuration:

```yaml
github:
  feedback:
    issue_workpad: true
    pr_body: true
    pr_sticky_comment: true
    trigger_reactions: true
    pr_comment_triggers: true
    commit_status: true
    check_run: false

    triggers:
      primary: "@open-symphony"
      aliases: ["@os"]
    inline_review_comments: false
    commit_comments: false

    summary:
      include_changed_files: true
      include_validation: true
      include_risks: true
      include_raw_output: false
      max_chars: 6000
```

The first implementation can expose a smaller subset:

```yaml
github:
  feedback:
    pr_sticky_comment: true
    trigger_reactions: true
    pr_comment_triggers: true
    commit_status: true
    triggers:
      primary: "@open-symphony"
      aliases: ["@os"]
```

Existing behavior should remain the default when the new configuration is absent.

## Event Model

Open Symphony should normalize agent lifecycle events before publishing them to GitHub.

Suggested internal events:

- `issue_claimed`
- `run_started`
- `agent_started`
- `agent_finished`
- `validation_started`
- `validation_finished`
- `branch_pushed`
- `pr_created`
- `pr_updated`
- `delivery_finished`
- `delivery_failed`
- `followup_requested`
- `run_blocked`

Each GitHub feedback surface subscribes to a subset of these events.

Example mapping:

| Event | Issue Workpad | PR Body | Sticky PR Comment | Reaction | Commit Status |
| --- | --- | --- | --- | --- | --- |
| `run_started` | update | no | update | `eyes` | pending |
| `validation_finished` | update | maybe | update | no | success/failure |
| `pr_created` | update | create | create | no | success |
| `delivery_failed` | update | no | update | no | failure/error |
| `followup_requested` | update | no | update | `eyes` | pending |

## Conversation Context Pack

When a GitHub issue run starts, Open Symphony should append a sanitized conversation context pack to the first agent prompt. The pack should include the issue identity, current workpad state, recent issue comments, and recent linked PR comments when a PR URL is present in the workpad. It must strip machine-readable workpad JSON markers and redact token-like secrets. It should be bounded and truncated instead of uploading unlimited comment history.

## Follow-Up Loop

Open Symphony should support follow-up commands from issue and PR comments. The canonical trigger is `@open-symphony`; `@os` is a short alias for the same command parser. Both forms should behave identically after trigger normalization.

Examples:

```md
@open-symphony address the review comments
```

```md
@os address the review comments
```

```md
@open-symphony fix the failing test and push to this PR
```

```md
@open-symphony explain why this approach was chosen
```

Rules:

- Normalize configured trigger aliases before command parsing.
- Only accept commands from users with write access or configured trusted users.
- Acknowledge accepted commands with a reaction.
- When `github.feedback.pr_comment_triggers` is enabled, polling open Open Symphony PRs should recognize `@open-symphony` and `@os` PR comments, map the PR branch back to the issue, acknowledge the comment, and continue on the existing PR branch.
- Continue on the existing PR branch when the command is on an Open Symphony PR.
- Create a new branch only when there is no active PR or the active PR is closed.
- Update the sticky PR comment and issue workpad after the follow-up run.
- Bound follow-up attempts with workflow configuration.

## Direct Reply Mode

Agents should decide from the latest user instruction whether code changes are required. If the request only asks for explanation, analysis, status, or guidance, the agent should write `.open-symphony/reply.md` and avoid repository edits. Symphony posts that artifact back to the source conversation and marks the workpad `reply_posted`. If repository changes are present, PR delivery remains the delivery path.

## Security and Privacy

Feedback must be sanitized before publishing to GitHub.

Do not publish by default:

- Raw prompts.
- Hidden reasoning.
- Full transcripts.
- Environment variables.
- API keys, tokens, or secrets.
- Local workspace paths.
- Hostnames or process IDs.
- Full command output unless explicitly enabled.

Validation summaries should include command names and exit codes by default. Full output should be opt-in and redacted.

## Permissions

Minimum personal token permissions for the default MVP:

- Read issues.
- Read and write issue comments.
- Read and write pull requests.
- Read and write contents for branches and commits.
- Read repository metadata.

Additional permissions for advanced surfaces:

- Commit statuses: statuses write.
- Check runs: checks write, usually via GitHub App.
- Review comments: pull requests write.
- Reactions: issues or pull requests write, depending on target event.

## MVP Scope

The next practical feature increment should include:

1. PR sticky comment creation/update.
2. Safer, richer PR delivery summary.
3. Trigger comment acknowledgement reaction.
4. Commit status for Open Symphony validation.
5. Conversation context pack injection for issue/PR follow-up runs.
6. Configuration flags for these surfaces.
7. Tests proving comments are updated in place and not duplicated.

Out of scope for this increment:

- Check runs.
- Inline review comments.
- Commit comments.
- Full transcript upload.
- Automated PR approval or merge.

## Acceptance Criteria

- A completed GitHub issue run updates exactly one issue workpad.
- A completed PR delivery creates or updates exactly one Open Symphony sticky PR comment.
- Re-running delivery updates the same sticky PR comment instead of creating duplicates.
- The PR body contains a concise delivery summary and validation section.
- Trigger comments using either `@open-symphony` or `@os` are accepted when aliases are configured.
- PR trigger comments requeue the linked issue when `pr_comment_triggers` is enabled and are not repeatedly reprocessed after claim.
- Answer-only runs can post `.open-symphony/reply.md` directly without opening a PR.
- A triggering comment receives an acknowledgement reaction when configured.
- The PR head commit receives an Open Symphony status when configured and permissions allow it.
- No raw prompts, secrets, local paths, hostnames, or PIDs are published.
- GitHub runs append a bounded conversation context pack containing recent issue and PR discussion.
- Existing workflows without `github.feedback` configuration behave as they do today.
