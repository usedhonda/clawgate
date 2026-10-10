# Communication restart guard harness

Run `scripts/tests/communication-restart-guard.sh` for the source-only guard
proof. It uses a fake canonical `gateway-restart` and check script, so it does
not contact a host, read credentials, stop a Gateway, or apply a plugin.

The harness proves that a partial manifest/current admission is rejected before
effects, and that an admitted maintenance path orders `check -> stop -> apply
-> start`.

## Staged route inputs

The staged Host A route additionally requires `CLAWGATE_COMMUNICATION_CANDIDATE_MANIFEST`
to be a project-relative JSON file with `version: 1`, the exact current Git
`base_revision`, and a unique `files` list of `{path, sha256}` entries. The
listed files are copied selectively into an inert `.runtime` candidate
stage, never into an ordinary source checkout. Bootstrap scripts (including the
signer and maintenance hooks) must themselves be declared and hashed. The
remote candidate is checked against the live Host A Git `HEAD`; local equality
is a separate prerequisite. After canonical Gateway stop, declared source files
are applied to the live repo with exact backups, while plugin/app artifacts are
applied with the same stopped-maintenance boundary; rollback restores only the
files touched by that operation before the canonical restart resumes. The
manifest/current admission files are supplied independently and are never
fabricated. Build and signed-bundle modes apply only after canonical Gateway
stop; ordinary sync/deploy without this candidate manifest is rejected before
effects.
