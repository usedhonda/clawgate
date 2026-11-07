# Security

## Reporting a vulnerability

Report vulnerabilities privately before posting exploit details or operational
data in a public issue. Use this repository's **Security → Report a vulnerability**
action when available, or contact the maintainer through an existing private
channel. Include the affected commit, the component, the trust boundary crossed,
and a minimal reproduction using synthetic data. Do not attach live credentials,
device identity keys, conversation captures, audio, or deployment configuration.

## Trust boundaries

ClawGate can read the screen, observe messages, record audio when enabled, and
operate terminal sessions according to the selected session mode. Accessibility,
screen-recording and microphone permissions give it access to personal data.
Installed native plugins and the local user account are trusted components.
Page content and received messages remain untrusted input; removing obvious
prompt markers does not make them trusted instructions.

The local bridge and optional remote transports have different admission
policies. Follow the current setup documentation for the selected transport;
do not expose the bridge directly to the public internet. OpenClaw plugin HTTP
routes must explicitly declare their authentication policy. Vibeterm telemetry
uses Gateway authentication, including the Gateway's explicit `mode: "none"`
opt-out; use authenticated access for real telemetry.
Telemetry request bodies have a 1 MiB limit and a 10-second complete-body
deadline; concurrent requests and deduplication memory are also bounded.

## Public repository hygiene

Keep credentials, persona overrides, `.local/`, `.runtime/`, runtime databases,
production receipts and environment files outside Git. Use placeholders for
local account paths, signing identities and private network names. Check
diagnostic archives manually before sharing: even when credentials are removed,
logs can contain sensitive messages, filenames or device information.

Run the local guard before publishing:

```bash
bash scripts/security-leak-check.sh --staged
bash scripts/security-leak-check.sh --all
```

The guard reports paths and line numbers while redacting matching content. It
checks tracked text and blocked credential-file paths; it is not a complete
secret inventory or a scan of Git history. If a real credential has been
published, revoke or rotate it. Deleting the current file does not remove it
from prior commits, clones, releases or logs.

## Verification scope

Automated tests cover protocol and input-validation regressions. macOS app
deployment, Accessibility behavior, browser reload, and live Gateway send/receive
acceptance require the corresponding runtime checks. A passing unit test suite
alone does not establish that a production installation has been updated.
These checks are targeted safeguards, not a guarantee that every security issue
in the repository or a particular deployment has been found.
