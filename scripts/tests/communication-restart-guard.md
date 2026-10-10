# Communication restart guard harness

Run `scripts/tests/communication-restart-guard.sh` for the source-only guard
proof. It uses a fake canonical `gateway-restart` and check script, so it does
not contact a host, read credentials, stop a Gateway, or apply a plugin.

The harness proves that a partial manifest/current admission is rejected before
effects, and that an admitted maintenance path orders `check -> stop -> apply
-> start`.
