# LOOP: current main WIP integration

GOAL: Preserve the existing user-owned dirty worktree, separate it into coherent changes,
finish only the already-started behavior, and leave `main` clean with verified logical commits.
This loop integrates the current WIP; it does not invent adjacent product work.

## PROJECT PROFILE

- Kind: closed. A permanently true end state exists: the current WIP is classified,
  verified, committed, and the worktree is clean.
- Baseline at authoring: `main` at `0282d0b`, with 13 modified files, one untracked test,
  and backup `stash@{0}` named `preserve main worktree before wave-floating-goal merge`.
- Current work clusters visible in the diff:
  1. Pet Log canonical storage/source-completeness behavior and contract tests/spec.
  2. Character manifest validation and regression tests.
  3. Pet test-isolation ordering changes across four fixture classes.
  4. Tiny floating-window test/spec deltas that must be classified before inclusion.
- Verification is multi-stage: focused Swift tests per cluster, then final leak/build/full-test,
  followed by the repository's mandatory local restart and health check.
- The worktree is the primary artifact. Never replace it wholesale with a branch, stash, or
  guessed historical version.

## SUCCESS CRITERIA (strict; no soft pass)

1. Every pre-existing dirty path is assigned to exactly one evidence-backed logical unit or
   explicitly restored because it is proven accidental; no user WIP is silently discarded.
2. Each logical unit has its focused old-fail/current-pass tests green, its contract doc updated
   when behavior changes, and one English conventional commit with no co-author trailer.
3. No conflict markers, staged foreign files, secrets, test weakening, skipped tests, feature
   disabling, drive-by refactors, or unexplained diff remain.
4. Final gate passes: `git diff --check`, security leak check, `swift build`, and full
   `swift test` with zero failures.
5. After the final successful build, `./scripts/restart-local-clawgate.sh` exits zero and
   `http://127.0.0.1:8765/v1/health` reports `ok: true`.
6. `git status --short` is empty. Pushing `main` is outside this loop unless the user separately
   authorizes it.

## STATE FILE

Use `.loop/main-wip-integration-state.md`. Read it before every iteration and append only new
evidence: selected unit, changed paths, focused gate, result, commit, and next unit. Resume from
state; never restart discovery from scratch.

## BUDGET

- iteration cap: 6
- no-progress streak: 2
- wall-clock cap: 90 minutes
- one logical unit per iteration

## VERIFY — cost-aware two-stage gate

Run the cheapest check capable of falsifying the current unit. Do not rerun an unchanged heavy
suite after every edit.

### Iteration pre-gate

1. `git status --short --branch`
2. `git diff --check`
3. Run only the focused test class(es) for the selected unit.

If a focused test is already red before that unit changes, record the exact baseline failure.
Do not broaden the fix beyond the selected unit.

### Iteration post-gate

1. Re-run the same focused test class(es).
2. Inspect `git diff --` and `git diff --cached --` with the selected unit's recorded paths.
3. Run `intent-guard check` for the unit before committing it.

### Final gate (once, after all units are committed)

Run in this order and stop at the first red:

```text
git diff --check
bash scripts/security-leak-check.sh --all
swift build
swift test
./scripts/restart-local-clawgate.sh
curl -fsS http://127.0.0.1:8765/v1/health
git status --short
```

Do not repeat the final gate unless source or test inputs changed after it.

## ITERATION 0 — inventory only

1. Re-read this contract, the state file, `AGENTS.md`, both Pet specs, and the complete current
   diff. Read `stash@{0}` only as a backup oracle; do not pop or drop it.
2. Record the current HEAD, origin relation, dirty paths, untracked paths, and stash identity.
3. Build a path-to-unit table. For each unit, record Task Intent, production paths, tests, spec,
   focused command, and expected commit subject.
4. If one path contains multiple units, plan an explicit hunk split. Do not commit the whole file
   merely because hunk selection is inconvenient.
5. If the diff cannot prove a change's intent, mark `needs-evidence`; inspect repository history,
   specs, and tests. Never guess and never delete it to make the tree clean.

## EACH IMPLEMENTATION ITERATION

1. Re-read contract and state; select the next smallest coherent unit only.
2. Start or refresh `intent-guard` with that unit's one-sentence intent and explicit exclusions.
3. Run the focused pre-gate. Capture the first real failure, not a summary.
4. Make the minimum change needed to finish the already-started unit. Preserve all unrelated WIP.
5. Run the focused post-gate and inspect the exact diff. A behavior/spec hotspot requires its
   guard test and contract doc in the same commit.
6. Stage only the selected unit or selected hunks. Verify with `git diff --cached --stat` and
   `git diff --cached` before committing.
7. Commit one logical unit using an English conventional subject and no `Co-Authored-By`.
8. Append evidence and the commit SHA to state. End the tick with `ITERATING` unless every unit is
   committed and the final gate passes.

## STOP WHEN

- `success`: all current WIP is accounted for, logical commits exist, final gate passes, restart
  is healthy, and the worktree is clean. Print `FINAL`.
- `no-progress`: two iterations add no verified unit or repeat the same action/plan. Record the
  blocker and stop without discarding WIP.
- `regression`: a previously green focused check turns red. Do not commit the unit.
- `failure`: the same focused failure survives three evidence-driven fixes.
- `budget`: iteration or wall-clock cap reached.
- `scope-boundary`: progress requires unrelated product behavior, remote writes, release, secrets,
  or destructive Git operations.

On any non-success stop, report the exact unit, first failing command/output, tried fixes, preserved
WIP location, and next evidence-backed action. Never claim partial work is final.

## RULES

- User-owned WIP is immutable outside the selected unit. No `reset --hard`, checkout-overwrite,
  force push, broad stash pop, mass formatting, or bulk file replacement.
- Keep `stash@{0}` until the worktree is clean and every logical commit is verified. Dropping it
  requires a separate explicit decision after success.
- No fake green: do not weaken assertions, add skips, delete tests, disable features, relax leak
  checks, or change expected output merely to match current behavior.
- Search before assuming. Tests and normative specs decide intent; summaries do not override source.
- Commit only Task-Intent-linked paths/hunks. Never stage `.env`, `.local`, credentials, build
  artifacts, app bundles, logs, or unrelated WIP.
- Maker != checker: before `FINAL`, use fresh-eyes diff review (subagent if available) against this
  contract and the final commit range. Findings must cite a file and behavior.
- Token efficiency is part of correctness: focused checks during iterations, one full gate at the
  final integration boundary, and no narration of unchanged passing output.
- No push, release, Host A/Gateway restart, or production deploy in this loop. The only runtime
  action is the mandatory local restart after the final successful build.
