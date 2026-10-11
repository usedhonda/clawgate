# Communication rollout safety contract

The communication candidate flow is source-only until the canonical restart
entry point admits it. The following invariants are required:

- A staged destination and every existing parent component must be a real
  directory inside the target project. `rsync` uses protected arguments so a
  path containing spaces cannot be re-parsed by the remote shell.
- The admitted remote script is executed by Bash because the shared helpers
  use Bash arrays and `BASH_SOURCE`.
- A normal Host A build uses the live project script and passes
  `CLAWGATE_COMMUNICATION_STAGED_BUILD=0`; only an admitted staged source sets
  it to `1`.
- Signing preferences are read from the selected `--project-path` after
  argument parsing. Private release credentials never enter a candidate stage.
- Each canonical communication restart receives a fresh lowercase 32-hex
  operation identity and the exact state root
  `.runtime/communication-maintenance/<id>`. Caller-supplied old IDs or backup
  roots are not trusted or reused. An apply failure before its operation starts
  must make rollback a no-op rather than consume an earlier successful
  operation.
- `CLAWGATE_COMMUNICATION_SKIP_PLUGIN_SYNC=1` permits a scripts-only operation;
  plugin source validation is not required in that mode.
- The signed-bundle branch treats the prepared app as immutable: its local
  restart invokes `restart-local-clawgate.sh` with `--skip-build --skip-sync
  --skip-plugin-sync --skip-sign`, so no build, resource copy, plugin sync, or
  signing can overwrite the prepared bundle.

`scripts/tests/communication-rollout-residuals.sh` is the bounded fake-tool
regression for these invariants. It does not SSH, build, sign, restart, or
deploy a host.
