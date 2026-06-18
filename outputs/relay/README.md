# Codex Remote Relay

Public relay prototype for reaching the Home Mac Bridge without exposing a home port.

The phone/watch client talks to this relay. The Home Mac runs `relay-client.mjs`, which long-polls this relay for commands, forwards them to the local Bridge, and posts results back.

## Start Locally

Terminal 1, Home Mac Bridge:

```bash
node outputs/home-mac-bridge/bridge.mjs --port 8787
```

Terminal 2, Relay:

```bash
RELAY_CLIENT_TOKEN=client-dev \
RELAY_BRIDGE_TOKEN=bridge-dev \
outputs/relay/start-relay.sh
```

Terminal 3, Home Mac outbound connector:

```bash
RELAY_BRIDGE_TOKEN=bridge-dev \
RELAY_URL=http://127.0.0.1:8788 \
outputs/home-mac-bridge/start-home-mac.sh
```

## Client API

Health:

```bash
curl http://127.0.0.1:8788/health
```

List Codex threads through the relay:

```bash
curl -H 'authorization: Bearer client-dev' \
  'http://127.0.0.1:8788/threads?limit=10'
```

Create a new Codex thread through the relay:

```bash
curl -X POST 'http://127.0.0.1:8788/threads' \
  -H 'authorization: Bearer client-dev' \
  -H 'content-type: application/json' \
  -d '{"text":"Reply exactly: RELAY_OK","ephemeral":true}'
```

Send or steer a message through the relay:

```bash
curl -X POST 'http://127.0.0.1:8788/threads/THREAD_ID/messages' \
  -H 'authorization: Bearer client-dev' \
  -H 'content-type: application/json' \
  -d '{"text":"Continue with this extra instruction"}'
```

Stream relay events:

```bash
curl -N -H 'authorization: Bearer client-dev' \
  http://127.0.0.1:8788/events
```

Register an iPhone APNs device token:

```bash
curl -X POST 'http://127.0.0.1:8788/devices' \
  -H 'authorization: Bearer client-dev' \
  -H 'content-type: application/json' \
  -d '{"token":"APNS_DEVICE_TOKEN","platform":"ios","appName":"CodexRemote"}'
```

## Completion Push Notifications

When the Home Mac Bridge forwards a `turn/completed` event, the relay emits a `notification_ready` event. If APNs is configured, it also sends a push notification to registered devices.

APNs configuration:

```bash
RELAY_CLIENT_TOKEN=client-dev \
RELAY_BRIDGE_TOKEN=bridge-dev \
APNS_KEY_PATH=/path/to/AuthKey_ABC123DEFG.p8 \
APNS_KEY_ID=ABC123DEFG \
APNS_TEAM_ID=YOURTEAMID \
APNS_TOPIC=com.chuxiaoyi.CodexRemote \
APNS_ENV=sandbox \
node outputs/relay/relay.mjs --port 8788
```

## Deploy

- Copy `.env.example` to `.env` and set long random `RELAY_CLIENT_TOKEN` and `RELAY_BRIDGE_TOKEN` values.
- Use `docker-compose.yml` to run Relay on server-local `127.0.0.1:8788`.
- Put Caddy or another HTTPS reverse proxy in front of it.
- For Alibaba Cloud, see `ALIYUN_DEPLOY.zh-CN.md`.

## Security Notes

- Set both `RELAY_CLIENT_TOKEN` and `RELAY_BRIDGE_TOKEN` before exposing the relay outside localhost.
- The Home Mac connector initiates outbound HTTP requests; the Home Mac does not need an open inbound port.
- Prefer exposing only HTTPS `443` publicly; keep Relay's raw `8788` port bound to `127.0.0.1`.
- This prototype keeps command queues and events in memory. A deployed relay should add persistence and rate limits.
- APNs push notifications are wired as an optional provider-token integration. They require an Apple Developer team, an APNs auth key, a matching app bundle id, and a real signed device build.
