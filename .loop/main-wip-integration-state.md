# Loop state — current main WIP integration

## Budget

iteration cap 6 / no-progress 2 / wall-clock 90min

## Seeded baseline (2026-08-12)

- branch/HEAD: `main` / `0282d0b`
- remote relation at authoring: `origin/main` matched `0282d0b`
- worktree: 13 modified files + 1 untracked test; no conflict markers
- backup oracle: `stash@{0}: On main: preserve main worktree before wave-floating-goal merge`
- diff size at authoring: 1,741 insertions / 329 deletions
- full gate: not run by makeloop; this file seeds the execution loop only

## Candidate units (must be confirmed from the full diff in iteration 0)

| unit | visible paths | status | focused verification |
| --- | --- | --- | --- |
| Pet Log storage/source completeness | `AmbientStorage.swift`, `AmbientLogPetView.swift`, Pet Log tests/spec | pending inventory | relevant Ambient Log/Pet Log test classes |
| Character manifest validation | `CharacterManifest.swift`, `CharacterManifestTests.swift` | pending inventory | `swift test --filter CharacterManifestTests` |
| Pet test isolation ordering | four PetModel fixture files + `PetLogTestIsolationOrderingTests.swift` | pending inventory | ordering test + affected fixture classes |
| Floating-window deltas | `PetFloatingWindowContractTests.swift`, `pet-floating-window-spec.md` | needs evidence | `swift test --filter PetFloatingWindowContractTests` |

## Iterations

No loop iteration has run yet.

## Last verified state

Contract generated only. Product WIP, tests, commits, runtime, stashes, and remotes were not changed.

## Next action

Run iteration 0: inventory the full diff, confirm logical units/hunk splits, and choose the smallest
focused unit. End with `ITERATING`; do not run the full suite during inventory.
