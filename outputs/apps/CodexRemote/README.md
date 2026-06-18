# Codex Remote Apps

Minimal iOS and watchOS clients for the Codex remote office flow.

## What Works

- iPhone app can configure Relay URL and client token.
- iPhone app can list recent Codex threads through the Relay.
- iPhone app can create a new Codex task.
- iPhone app can send an additional instruction to an existing thread; active threads are steered by the Home Mac Bridge.
- iPhone app can request notification permission, register with APNs, and post the device token to the Relay.
- iPhone app can stream foreground Relay events, including completion notification readiness.
- iPhone app can use GitHub Issues as a no-server backend for creating tasks and adding comments.
- iPhone app can sync Relay/GitHub settings to the Watch app with WatchConnectivity.
- Watch app can type or dictate a new task and send it to the Relay.
- Watch app can refresh recent threads, open a thread, and type or dictate an additional instruction.
- Watch app can use the same GitHub Issues backend for issue creation and comments.
- Watch app can receive settings from iPhone or request them when the iPhone app is open.

The Watch text fields use the system watchOS text input experience, which includes dictation on real devices when available.

## Open

```bash
open outputs/apps/CodexRemote/CodexRemote.xcodeproj
```

Schemes:

- `CodexRemote` for iPhone
- `CodexRemoteWatch` for Apple Watch

## Local Build Checks

```bash
xcodebuild -project outputs/apps/CodexRemote/CodexRemote.xcodeproj \
  -scheme CodexRemote \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

```bash
xcodebuild -project outputs/apps/CodexRemote/CodexRemote.xcodeproj \
  -scheme CodexRemoteWatch \
  -destination 'platform=watchOS Simulator,name=Apple Watch Series 11 (46mm)' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## Real Device Notes

Remote push notifications require:

- An Apple Developer team.
- Bundle id matching `com.chuxiaoyi.CodexRemote`, or update `PRODUCT_BUNDLE_IDENTIFIER` and `APNS_TOPIC` together.
- Push Notifications capability enabled for the app id.
- A provisioning profile that includes `aps-environment`.
- An APNs `.p8` auth key configured on the Relay with `APNS_KEY_PATH`, `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_TOPIC`, and `APNS_ENV`.

For local simulator testing, use the Relay and Home Mac Bridge READMEs. For real remote use, deploy `outputs/relay/relay.mjs` to a public HTTPS host and run `outputs/home-mac-bridge/relay-client.mjs` on the Home Mac.

For GitHub no-server mode, fill the GitHub owner, repo, label, and token on iPhone first, then tap `Sync Settings to Watch`. On Watch, `Request iPhone Settings` can ask the open iPhone app to resend the same configuration.
