# Engineering Gates

Open Symphony is an agent harness. Changes that affect orchestration, external systems, shell
execution, publishing, or security boundaries must be validated as harness changes, not only as
ordinary library changes.

These gates encode the repository-level feedback loops we expect agents to follow before handoff.
They are intentionally mechanical so review findings become regression tests instead of recurring
review comments.

## Baseline Gate

Run targeted tests while iterating. Before handoff, run the full local gate:

```bash
cd elixir
mix compile --warnings-as-errors
mix specs.check
mix test
git diff --check
```

When practical, also run the directory gate documented in `elixir/AGENTS.md`:

```bash
cd elixir
make all
```

If a command cannot run in the current environment, document the exact missing prerequisite and the
highest-confidence targeted checks that did run.

## Risk Matrix Gate

Before considering a change complete, classify whether it touches any of these risk areas:

| Risk area | Examples | Required validation |
| --- | --- | --- |
| Shell execution | `System.cmd`, hooks, `bash -lc`, external CLIs | Real local command-path test plus timeout/error test |
| Git mutation/publishing | commit, push, branch checkout, PR creation, labels | Local git integration test using an isolated repo/remote |
| External API writes | tracker comments, issue state, PR labels, workpad updates | Mock/API-boundary tests that assert request payloads and error handling |
| Claiming/concurrency | issue claims, leases, retries, worker lifecycle | State-machine tests for active, expired, foreign, and lost claims |
| Untrusted input | issue title/body/comments, labels, reviewer feedback | Spoofing/injection tests and normalization tests |
| Secret/log exposure | command output, validation output, workpad metadata | Security regression tests for redaction and metadata minimization |
| Lifecycle semantics | active/terminal states, review feedback loops, cleanup | Tests for each state transition and docs/spec alignment |

If any row applies, the required validation must either be added or an explicit rationale must be
written in the PR/test notes explaining why the row does not apply to this implementation path.

## GitHub Extension Gate

Any change touching `SymphonyElixir.GitHub.*`, GitHub tracker config, or GitHub delivery must include
or preserve tests for these extension behaviors.

### Candidate Query

- open issues are fetched from the configured owner/repo
- pull request items returned by the issues API are skipped
- include labels and exclude labels are applied
- assignee filtering is honored, including `@me`
- pagination preserves order
- spoofed workpad comments from non-bot authors are ignored
- `pr_open` pauses re-dispatch only until the issue is updated after delivery

### Claims and Workpad

- no workpad creates a bot-owned workpad
- existing bot-owned workpad is reused
- workpad comments from other authors are ignored
- active foreign claim skips dispatch
- expired claim can be reclaimed
- write-lost claim confirmation skips dispatch
- owned workpad updates renew the active lease
- workpad metadata avoids local workspace paths, hostnames, PIDs, and credentials

### Delivery

- `prepare_workspace/2` exercises a real local git repository
- `deliver/3` has a success-path test with a local bare remote
- dirty changes are committed and pushed to the expected branch
- validation pass/fail paths are covered
- existing open PRs are reused
- new PR creation payload is asserted
- PR labels are applied
- workpad delivery state is updated with bounded public metadata
- command timeouts are exercised without relying on unsupported `System.cmd` options

### Security Regressions

- suspicious untracked secret files are not auto-committed
- validation output is not blindly written to public workpad state
- command and API errors are redacted before becoming issue-visible text
- untrusted issue/comment content cannot forge claims or terminal delivery state

## Real Integration Profile

The default CI/local gate should remain deterministic and not require real GitHub credentials. A
separate real-integration profile may be added for production readiness. If enabled, it must:

- use isolated test repositories, issues, labels, branches, and comments
- clean up created artifacts when practical
- explicitly skip when credentials or permissions are absent
- fail when explicitly enabled and the integration behavior fails

## Review Finding Rule

For every HIGH or CRITICAL review finding, add a regression test before or alongside the fix unless
the finding is purely documentation-only. The regression test should fail on the reviewed behavior
and pass after the fix.
