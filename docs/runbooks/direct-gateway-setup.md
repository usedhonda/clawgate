# Direct Gateway Setup

Connect an OpenClaw Gateway to a ClawGate bridge on a trusted network without
requiring federation. First check the [host compatibility notes](../openclaw-compatibility.md):
custom minutes, ambient, and messaging contracts are not automatically available
in an upstream OpenClaw installation.

## The two connections

| Connection | Destination | Configuration |
| --- | --- | --- |
| Native pet → Gateway WebSocket | Gateway host, normally port 18789 | ClawGate Settings: OpenClaw host and port; local Gateway credential |
| Gateway plugin → ClawGate HTTP API | Bridge host, port 8765 | OpenClaw `channels.clawgate.<accountId>.apiUrl` |

Do not use a bridge URL as the pet's Gateway URL.

## Network access

The current app listens on `0.0.0.0:8765`. The HTTP API accepts loopback and
source addresses in the CGNAT range used by Tailscale. It does not authenticate
those addresses as individual Tailscale users or devices, and it does not check
a bridge bearer token. `/v1/health` is public liveness only.

Use a host firewall and tailnet ACLs to restrict port 8765 to trusted peers.
Do not publish it through a public reverse proxy or an untrusted local proxy:
a proxy can make every caller appear to be the same trusted source. The API can
send adapter actions and expose the Gateway credential through its bootstrap
endpoint, so access grants substantial authority.

`remoteAccessEnabled` and `remoteAccessToken` are retired settings. The old
`PUT /v1/config` examples do not apply; the app has no such update route.

## Configure the Gateway plugin

Install the plugin following its [README](../../extensions/openclaw-plugin/README.md)
and the compatibility notes. Set the account's `apiUrl` in the OpenClaw config:

```json
{
  "channels": {
    "clawgate": {
      "default": {
        "apiUrl": "http://bridge.example-tailnet.ts.net:8765"
      }
    }
  }
}
```

The hostname is a placeholder; use the address of your trusted bridge host.
The plugin still supports a `token` option for explicitly configured authenticated
frontends, but that token is not the native bridge's access control.

Configure the app's Gateway host and port in Settings, using the Gateway's
address rather than the bridge address. Keep the Gateway's own authentication
enabled. Do not copy credentials into the repository or public diagnostics.

Use the canonical restart flow for the actual deployment. A source or unit-test
pass does not establish that the running Gateway loaded the edited plugin.

## Verify

From a trusted Gateway host:

```bash
curl --fail --max-time 10 http://bridge.example-tailnet.ts.net:8765/v1/health
curl --fail --max-time 10 http://bridge.example-tailnet.ts.net:8765/v1/doctor
```

Check plugin startup and one fresh event in the running environment. Do not
replay historical messages or treat a health response as end-to-end delivery.
`/v1/openclaw-info` returns a credential; do not paste its response into an issue.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Health works but other routes return 403 | Source-network policy and browser-origin checks; health is not an authorization test |
| Gateway cannot reach the bridge | Correct host and port, host firewall, tailnet ACLs, bridge process |
| Pet connects to the wrong Gateway | ClawGate Settings host/port take precedence for the connection destination |
| Events arrive but specialized features fail | Required custom Gateway capabilities, plugin SDK compatibility, and feature-specific admission |
| Changed plugin behaves like the old version | Canonical restart and actual loaded plugin path/version |
