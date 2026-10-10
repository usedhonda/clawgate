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
listed files are copied selectively to the remote source checkout as candidate
staging; no installed plugin/app apply occurs until stopped maintenance. The
manifest/current admission files are never fabricated or copied. The remote
host must already have the exact communication manifest/current paths. Build
and signed-bundle modes apply only after canonical Gateway stop; ordinary
sync/deploy without this candidate manifest is rejected before effects.
