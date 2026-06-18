# Codex Home Mac Bridge

Local-only prototype for controlling Codex Desktop from another client.

The bridge starts the bundled Codex CLI app-server over stdio:

```bash
/Applications/Codex.app/Contents/Resources/codex app-server --stdio
```

Then it exposes a small HTTP API on `127.0.0.1`.

## Start

```bash
node bridge.mjs --port 8787
```

Optional bearer token:

```bash
BRIDGE_TOKEN=dev-secret node bridge.mjs --port 8787
```

Verbose debugging events:

```bash
node bridge.mjs --debug-events
```

Outbound relay connector:

```bash
RELAY_BRIDGE_TOKEN=bridge-dev \
RELAY_URL=http://127.0.0.1:8788 \
./start-home-mac.sh
```

No-server GitHub Issues connector:

```bash
CODEX_REMOTE_BACKEND=github \
GITHUB_TOKEN=github_pat_replace_me \
GITHUB_OWNER=your-user \
GITHUB_REPO=codex-remote \
./start-home-mac-github.sh
```

Install as a login-time LaunchAgent:

```bash
cp home-mac.env.example ~/.codex-remote-home-mac.env
nano ~/.codex-remote-home-mac.env
./install-launch-agent.sh
```

Check status:

```bash
./status-launch-agent.sh
```

Uninstall:

```bash
./uninstall-launch-agent.sh
```

## API

Health:

```bash
curl http://127.0.0.1:8787/health
```

Recent threads:

```bash
curl 'http://127.0.0.1:8787/threads?limit=10'
```

Create a new thread:

```bash
curl -X POST 'http://127.0.0.1:8787/threads' \
  -H 'content-type: application/json' \
  -d '{"text":"Reply exactly: BRIDGE_OK","ephemeral":true}'
```

Read a thread:

```bash
curl 'http://127.0.0.1:8787/threads/THREAD_ID'
```

Send a message to a thread:

```bash
curl -X POST 'http://127.0.0.1:8787/threads/THREAD_ID/messages' \
  -H 'content-type: application/json' \
  -d '{"text":"Reply exactly: BRIDGE_OK"}'
```

If the thread is idle, the bridge starts a new turn with `turn/start`.
If the thread is already active, the bridge appends the text to the current turn with `turn/steer`.

Stream events:

```bash
curl -N http://127.0.0.1:8787/events
```

With token:

```bash
curl -H 'authorization: Bearer dev-secret' http://127.0.0.1:8787/health
```

## Current Scope

- Uses real Codex `app-server --stdio`.
- Supports `thread/list`, `thread/read`, `thread/start`, `thread/resume`, `turn/start`, and `turn/steer`.
- Streams Codex notifications with Server-Sent Events.
- Enriches `turn/completed` events with accumulated assistant text from `item/agentMessage/delta`.
- Filters noisy local debug events by default, including stderr, token usage, and account rate-limit updates.
- Defaults to local-only bind host `127.0.0.1`.
- Includes `relay-client.mjs` so the Home Mac can connect outbound to a public relay.
- Includes `github-issues-client.mjs` so the Home Mac can use a private GitHub repo as a no-server task inbox.
- Includes LaunchAgent helpers so the Home Mac side can start at login and restart after failures.

## Known Limits

- Some active turns are not steerable, including review and manual compact turns; those return `409 turn_not_steerable`.
- Approval and user-input server requests are surfaced as events but not handled.
- This should not be exposed directly to the public internet.
- The mobile clients and APNs Relay integration live under `outputs/apps/CodexRemote` and `outputs/relay`.
