# Legacy scripts (retired 2026-04-10)

These scripts belong to the self-signed `ClawGate Dev` cert era that
ended on 2026-04-10, when ClawGate migrated to signing with
`Developer ID Application: Yuzuru Honda (F588423ZWS)`.

They are kept here only as historical reference. **Do not run them for
new work.** Running `setup-cert.sh` or `setup-cert-macmini.sh` will
generate a fresh self-signed cert, which invalidates the TCC
(Accessibility / Screen Recording) bindings that are now tied to the
stable Developer ID identity.

## Canonical replacements

| Old (this folder) | New (canonical) |
|---|---|
| `setup-cert.sh` | none — `.local/secrets/release.env` holds `SIGNING_ID`, and the Developer ID identity is imported from `.local/secrets/clawgate-devid.p12` |
| `setup-cert-macmini.sh` | `scripts/macmini-local-sign-and-restart.sh` (auto-sources release.env, prefers Developer ID) |
| `macmini-cert-oneclick.sh` | `scripts/macmini-local-sign-and-restart.sh` |
| `fix-macmini-ax-permission.sh` | not needed — Developer ID preserves TCC across rebuilds. On the rare one-time cert migration, `tccutil reset Accessibility com.clawgate.app` + an explicit Allow click is enough. |

## Why keep them at all?

If the Developer ID path ever fails catastrophically (account lapsed,
cert revoked, private key lost), these scripts are the documented way
to fall back to a self-signed dev identity. That is the **only** case
where they should be consulted, and even then, the canonical rule in
`memory/feedback_tcc_stable_signing.md` should be checked first.
