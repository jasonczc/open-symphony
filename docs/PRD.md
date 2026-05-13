# Open Symphony PRD

## 1. Product Summary

Open Symphony is a GitHub-native orchestration layer for autonomous coding agents. It turns GitHub Issues into isolated implementation runs, coordinates local agent CLIs such as Codex and Claude, manages pull request delivery, and records progress in durable GitHub comments.

The initial product should be a lightweight, local-first system that builds on the OpenAI Symphony model while adapting it for GitHub Issues, GitHub Pull Requests, and locally authenticated developer tooling.

## 2. Goals

- Use GitHub Issues as the primary task queue.
- Run coding agents in isolated per-issue worktrees.
- Support local official agent CLIs, starting with Codex and Claude.
- Reuse the operator's existing local authentication and subscriptions where possible.
- Create and maintain pull requests automatically.
- Keep a persistent issue workpad comment as the source of truth for progress.
- Provide a reliable execution loop with claims, retries, timeouts, and recovery.
- Enable incremental expansion toward multi-agent review and verification workflows.

## 3. Non-Goals

- Building a hosted SaaS product in the first version.
- Replacing GitHub Issues, GitHub Pull Requests, or GitHub Actions.
- Building a full multi-agent team runtime in the first version.
- Automatically merging production code without explicit configuration.
- Supporting every issue tracker or agent runtime initially.
- Requiring users to move work management into a separate dashboard.

## 4. Target Users

### Primary User

A developer or small engineering team that already uses GitHub Issues and wants local autonomous coding agents to work through issues with minimal supervision.

### Secondary User

An engineering lead who wants a controlled automation layer that can coordinate implementation, validation, PR creation, and review feedback handling while keeping all state visible in GitHub.

## 5. Core User Stories

### Issue Execution

- As a developer, I can label or assign a GitHub Issue so Open Symphony picks it up.
- As a developer, I can see which agent claimed an issue and what it is doing.
- As a developer, I can stop automation by removing a label, closing the issue, or issuing a stop command.

### Workspace Isolation

- As a developer, each issue run happens in its own git worktree.
- As a developer, agent commands never run in the source repository root by default.
- As a developer, failed or completed workspaces can be inspected before cleanup.

### Agent Execution

- As a developer, I can choose Codex or Claude as the implementation agent.
- As a developer, I can configure the agent command without changing source code.
- As a developer, I can set max turns, timeouts, and retry limits.

### Pull Request Delivery

- As a developer, completed work is pushed to a branch and opened as a draft pull request.
- As a developer, the PR links back to the issue.
- As a developer, the PR body contains a summary, validation evidence, risks, and remaining blockers.

### Progress Tracking

- As a developer, every managed issue has one persistent Open Symphony workpad comment.
- As a developer, the workpad shows plan, acceptance criteria, validation, current state, PR link, and blockers.
- As a developer, Open Symphony updates the existing workpad instead of posting noisy status comments.

### Feedback Loops

- As a developer, when CI fails, Open Symphony can collect failure context and ask the agent to fix it.
- As a developer, when PR review comments request changes, Open Symphony can ask the agent to address them.
- As a developer, feedback loops are bounded by configurable max attempts.

## 6. Functional Requirements

## 6.1 GitHub Issue Tracker

Open Symphony must support a GitHub tracker with the following capabilities:

- Fetch open candidate issues.
- Filter by labels.
- Exclude issues by labels.
- Filter by assignee, including an operator-friendly `@me` option.
- Fetch a single issue by number.
- Fetch current issue state.
- Read issue comments.
- Create and update issue comments.
- Add and remove labels.
- Optionally close issues when configured.

Candidate issues are eligible only when all configured inclusion filters match and no configured exclusion filter applies.

## 6.2 Claiming

Open Symphony must prevent duplicate work on the same issue.

Minimum claim behavior:

- Before dispatch, write or verify a machine-readable claim marker.
- A claim includes issue number, run ID, host, PID, workspace path, timestamp, and expiration.
- If an active unexpired claim exists from another runner, skip the issue.
- If a claim expires and no matching local run exists, the issue may be reclaimed.
- On normal completion, release or mark the claim complete.

The claim marker may initially live inside the persistent workpad comment.

## 6.3 Workpad Comment

For each managed issue, Open Symphony must maintain exactly one active workpad comment with this marker:

```md
## Open Symphony Workpad
```

The workpad should include:

- Status
- Current run ID
- Agent runner
- Workspace path
- Branch
- Pull request URL
- Plan
- Acceptance criteria
- Validation checklist
- Recent events
- Blockers

Open Symphony should update the existing workpad comment whenever possible.

## 6.4 Workspace Management

Open Symphony must create isolated workspaces for each issue.

Requirements:

- Use git worktrees when the project is a git repository.
- Create branches using a stable prefix, for example `open-symphony/<issue-number>-<slug>`.
- Reuse an existing issue workspace when continuing a run.
- Verify workspace paths stay under the configured workspace root.
- Support hooks for setup and cleanup.
- Preserve failed workspaces by default for inspection.

## 6.5 Agent Runner Abstraction

Open Symphony must define a runner interface independent of a specific agent.

Initial runner types:

- `codex-cli`
- `claude-cli`
- `shell`

Runner configuration should include:

- command
- arguments
- environment inheritance policy
- working directory
- timeout
- max turns
- permission or sandbox mode where supported

The first implementation may run one primary implementation agent per issue.

## 6.6 Prompt Rendering

Open Symphony must render issue-specific prompts from `WORKFLOW.md`.

Prompt context must include:

- issue number
- issue title
- issue body
- issue labels
- issue URL
- branch name
- workspace path
- attempt number
- existing PR URL when available
- workpad content when available

The default prompt must instruct the agent to:

- Work only inside the provided workspace.
- Implement the issue requirements.
- Update local code and tests.
- Commit changes locally.
- Not push branches or create PRs unless explicitly configured.
- Report blockers clearly.

## 6.7 PR Lifecycle

Open Symphony must own the PR lifecycle by default.

Requirements:

- Detect whether an open PR already exists for the issue branch.
- Push the branch after successful local validation or when configured.
- Create a draft PR if none exists.
- Link the PR to the issue.
- Add configured labels to the PR.
- Update the PR body with summary, validation, and known risks.
- Record the PR URL in the workpad.

The agent should not be required to create the PR itself.

## 6.8 Validation

Open Symphony must support configurable validation commands.

Examples:

```yaml
validation:
  commands:
    - npm test
    - npm run lint
```

Requirements:

- Run validation in the issue workspace.
- Capture command, exit code, and relevant output summary.
- Record validation results in the workpad and PR body.
- Block PR readiness when required validation fails.

## 6.9 CI Feedback Loop

Open Symphony should support a bounded CI repair loop.

Requirements:

- Detect GitHub Actions status for the PR branch.
- Wait for required checks when configured.
- If checks fail, collect failure summary and logs when available.
- Resume the agent with CI failure context.
- Push fixes and wait again.
- Stop after `max_ci_fix_rounds`.

## 6.10 Review Feedback Loop

Open Symphony should support a bounded review repair loop.

Requirements:

- Read PR review states.
- Read top-level PR comments.
- Read inline review comments.
- Identify unresolved actionable feedback.
- Resume the agent with review context.
- Push fixes.
- Update the workpad with addressed feedback.
- Stop after `max_review_fix_rounds`.

## 6.11 State Machine

Open Symphony should use an explicit issue run state machine.

Initial states:

```text
queued
claimed
planning
coding
validating
pr_open
ci_wait
ci_fix
review_wait
review_fix
ready
blocked
done
failed
```

A first version may implement a simplified subset:

```text
queued → claimed → coding → validating → pr_open → ready
```

## 6.12 Commands

Open Symphony should eventually support issue and PR commands through comments.

Initial command syntax:

```text
@open-symphony run
@open-symphony stop
@open-symphony retry
@open-symphony status
```

Commands may be implemented after the polling MVP.

## 6.13 Configuration

Open Symphony must be configured by a Markdown workflow file with YAML front matter.

Example:

```md
---
tracker:
  kind: github
  owner: example-org
  repo: example-repo
  labels: [open-symphony]
  exclude_labels: [blocked]
workspace:
  root: .open-symphony/worktrees
agent:
  type: codex-cli
  command: codex
  max_turns: 5
  timeout_ms: 3600000
git:
  branch_prefix: open-symphony/
pr:
  draft: true
  labels: [open-symphony]
validation:
  commands:
    - npm test
limits:
  max_ci_fix_rounds: 3
  max_review_fix_rounds: 3
---

You are working on GitHub issue #{{ issue.number }}.

Title: {{ issue.title }}

Description:
{{ issue.body }}
```

## 7. Non-Functional Requirements

## 7.1 Safety

- Agent processes must run in the issue workspace by default.
- The source repository root must not be used as an agent working directory.
- Secrets must not be printed into workpad comments, PR bodies, or logs.
- Issue and PR text must be treated as untrusted input.
- Dangerous operations require explicit configuration.

## 7.2 Reliability

- Open Symphony must tolerate process restarts.
- State should be recoverable from local state files and GitHub comments.
- In-progress runs should be detectable after restart.
- Retry behavior must be bounded and visible.

## 7.3 Observability

Minimum observability:

- CLI status command.
- Structured local logs.
- Workpad updates.
- Run IDs for correlation.

Future observability:

- Local dashboard.
- JSON API.
- Event stream.
- Token and runtime accounting.

## 7.4 Portability

- The first version should run locally on macOS and Linux.
- GitHub access should work through `gh` CLI or GitHub token configuration.
- Agent CLI authentication should reuse existing local setup when possible.

## 8. MVP Scope

The MVP is successful when a user can:

1. Configure a repository with `WORKFLOW.md`.
2. Label a GitHub Issue for automation.
3. Start Open Symphony locally.
4. See the issue claimed and a workpad comment created.
5. See an isolated worktree and branch created.
6. Have the configured agent implement and commit changes.
7. Have Open Symphony run configured validation.
8. Have Open Symphony push the branch and create a draft PR.
9. See the PR URL and validation results in the issue workpad.

## 9. Milestones

## Milestone 1: GitHub MVP

- GitHub issue polling.
- Label and assignee filtering.
- Workpad comment create/update.
- Local claim marker.
- Worktree creation.
- Single runner execution.
- Branch push.
- Draft PR creation.
- Basic validation command support.

## Milestone 2: Delivery Loop

- PR detection and update.
- CI status polling.
- CI failure context collection.
- Bounded CI fix loop.
- Review comment collection.
- Bounded review fix loop.
- Better run recovery.

## Milestone 3: Multi-Runner Review

- Separate implementer and reviewer runners.
- AI review gate before PR readiness.
- Reviewer findings written to workpad.
- Implementer repair loop for blocking AI review findings.

## Milestone 4: Operator Experience

- CLI status command.
- Local run logs by issue.
- Optional local dashboard.
- Config validation.
- Setup wizard.

## 10. Success Metrics

- Time from labeled issue to draft PR.
- Percentage of runs that create a PR without human intervention.
- Percentage of PRs passing validation on first attempt.
- Number of CI fix loops per PR.
- Number of review fix loops per PR.
- Manual intervention rate.
- Failed or stuck run rate.

## 11. Open Questions

- Should GitHub operations use `gh` CLI first, GitHub REST/GraphQL first, or support both?
- Should the initial implementation live inside the existing Elixir reference implementation or as a new lightweight runtime?
- Should labels or GitHub Projects represent workflow state in the first version?
- Should agent-created commits be signed or attributed to the local user by default?
- What is the default cleanup policy for successful and failed workspaces?
- Should PR creation be mandatory, or should issue-closing tasks be supported without PRs?
