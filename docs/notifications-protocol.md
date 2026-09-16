# Notification protocol and trust boundary

Herdr Companion notifications are opt-in. The iOS app registers through its existing pinned SSH connection; the separate Mac helper watches only official Herdr JSON snapshots/events and sends generic alerts directly to Apple Push Notification service (APNs). Official Herdr is not patched, fork-only notification methods are not called, and there is no Herdr-operated relay.

## Fixed SSH RPC

The app executes one reviewed command:

```text
$HOME/Library/Application Support/Herdr Companion Notifications/bin/herdr-notification-helper rpc
```

Before execution, the fixed command checks the account home, `Library`, and `Application Support` ancestors for current-user ownership, directory type, no symlink, and no group/world write access. The notification root and `bin` must additionally be private current-user directories, and the helper must be a current-user regular executable with no group/world write bits. A single newline-delimited JSON request (maximum 16 KiB) is written to stdin, and a single JSON response (maximum 16 KiB) is read from stdout. The helper treats newline as the complete frame without waiting for EOF. The app gives the dedicated SSH exec/client a 20-second application deadline and closes it on timeout or cancellation. Device tokens never appear in command arguments, shell source, logs, or diagnostics. The client exposes no arbitrary helper command entry point.

Protocol version 1 supports:

| Operation | Required data | Effect |
| --- | --- | --- |
| `status` | optional complete device/route/session tuple | Reports helper configuration and route state. |
| `register` | validated device registration | Adds or rotates a token and merges the saved-host route. |
| `unregister_route` | device, saved-host, session IDs | Removes only that saved-host route. |
| `set_preferences` | route tuple and both alert booleans | Changes categories after durable acknowledgement. |
| `set_workspace_muted` | route tuple, opaque workspace ID, boolean | Changes one workspace mute after durable acknowledgement. |
| `test_notification` | route tuple | Requests a real APNs delivery; there is no local fake-success path. |

UUIDs identify an app installation and a local saved-host record. Official session names and bounded printable opaque Herdr IDs are validated. Fields unused by an operation are rejected. A registration can be durably saved while APNs credentials are absent, but the response is explicitly `registered_unconfigured`, never “enabled.”

## Stored state and multi-device behavior

The helper keeps `state.json`, `state.lock`, and `config.json` under its private application-support directory. Directories must be user-owned with mode `0700` or stricter; files must be user-owned regular files with mode `0600` or stricter, and symlinks are rejected. State updates are locked and atomically replaced.

Each iPhone or iPad installation has a device UUID and APNs token. Each saved-host route has its own preferences, workspace mutes, and random 256-bit routing secret. Multiple devices may subscribe to the same Herdr session. Token rotation replaces the old token. Duplicate saved-host routes for the same physical token/session remain independently editable but send once, using the most recently selected route for navigation and its settings. Disabling or deleting a saved host removes only its route; the app retains desired state separately from last acknowledged helper state and keeps failed changes visibly pending for the next connection/foreground reconciliation. Deletion waits for remote unregister acknowledgement. iOS backgrounding does not unregister.

## Event semantics and deduplication

The helper uses official `agent.list` state plus `events.subscribe`; it never reads terminal content. Instance identity includes the complete official `agent_session` semantics. A helper-private HMAC of that identity, combined with the official session and terminal, keys transition state; raw `id` or `path` values are never persisted. Pane and workspace must still remain equal across a transition.

- The first snapshot seeds state and emits nothing, including for an already-blocked agent.
- A newly observed `blocked` transition emits “Needs your attention,” including after reconnect when it is a positive current observation.
- “Finished responding” requires a live, ordered transition from `working` to `idle` or `done` for the same terminal and pane.
- Initial idle, reconnect-to-idle, unknown/missing/deleted agents, out-of-order state sequence numbers, pane/terminal reuse by another agent instance, and network loss never produce a completion alert. An atomic roster removes disappeared identities so a replacement seeds cleanly even if pane and terminal IDs are reused.
- Persistent transition state suppresses duplicate stream/reconnect events. Leaving an alerting state re-arms a later cycle even with an older server that omits sequence numbers. Entries expire after seven days and are bounded to 4,096.

Preferences and workspace mutes are applied when destinations are selected, so a muted workspace stops delivery after its acknowledged state update. Devices with the same environment/token are coalesced for one event.

## APNs boundary

The helper signs ES256 provider tokens with the configured `.p8` file using CryptoKit, then posts through Foundation URLSession to Apple’s fixed production or sandbox HTTP/2 endpoint. The key must be a user-owned regular file with no group/world permission bits and cannot be a symlink. Provider tokens are cached for less than 50 minutes. Transient HTTP 429/500/503 and transport failures receive at most three total attempts with capped backoff; bad/unregistered device tokens are removed without retry.

The visible payload contains only the generic title `Herdr Companion` and one of:

- `Needs your attention`
- `Finished responding`

The nested `herdr` route contains only protocol/version, alert kind, local saved-host UUID, opaque workspace/pane/terminal IDs, a per-route HMAC binding of the official agent instance, optional state-change sequence, and emission time. The HMAC key stays in the saved route and is never included in the push. The route contains no raw agent-session value, host, path, username, command, prompt, transcript, output, or credential. The app rejects malformed, future-dated, or more-than-15-minute-old routes and requires a fresh topology agent whose recomputed binding matches before navigation. Missing/unsupported identity fails closed.
