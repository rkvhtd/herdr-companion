# Optional notification setup

The current app target always requests the `aps-environment` entitlement. Any physical-device build therefore needs a push-capable App ID and provisioning profile, even when you do not enable notification use at runtime. A missing requested capability can fail signing or provisioning before launch. Runtime notification use remains optional. Real APNs delivery is not verified by the tests in this repository.

Sending alerts additionally requires a physical iPhone or iPad, an APNs token-signing key, and the separate helper on every saved Mac that should send those alerts. Simulator builds validate the UI and routing logic but are not evidence of a real APNs delivery.

This setup does not install anything automatically, does not discover Apple accounts or signing keys, and must not be run with production credentials in a test fixture. Simulator and unit tests are not evidence of real APNs delivery; that path remains optional and unverified here. Debug builds request the APNs `development` environment; Release builds request `production`.

## 1. Sign the app for APNs

Generate the Xcode project, select the **HerdrCompanion** app target, and choose the intended Apple Developer team. The committed entitlements file always requests `aps-environment` (`development` in Debug, `production` in Release), so the App ID and provisioning profile used for a physical device must include the Push Notifications capability. If the bundle identifier changes from `com.elysium.herdrcompanion`, use the same identifier as the APNs topic in the Mac configuration.

A profile that lacks the requested push capability can fail codesigning or provisioning before the app launches. After a successful install, a missing APNs environment configuration is shown as a registration failure rather than as enabled.

## 2. Build and stage the Mac helper

On the Mac, from this checkout:

```bash
swift build -c release --product herdr-notification-helper
install -d -m 700 "$HOME/Library/Application Support/Herdr Companion Notifications/bin"
install -m 700 .build/release/herdr-notification-helper "$HOME/Library/Application Support/Herdr Companion Notifications/bin/herdr-notification-helper"
```

The iOS app will call only that exact user-owned path through the already pinned SSH connection. The notification root and `bin` must remain current-user private directories (`0700` or stricter), the helper must remain a current-user regular executable with no group/world write bits, and the home/`Library`/`Application Support` ancestors must not be symlinks or group/world writable. Permission drift is rejected before the helper receives a registration token.

## 3. Install private APNs configuration

Create an APNs token-signing key in the Apple Developer portal. Copy the downloaded `.p8` into a private user-owned location; do not add it to this repository or paste it into logs. For example:

```bash
install -m 600 /private/path/to/AuthKey_KEYID.p8 "$HOME/Library/Application Support/Herdr Companion Notifications/AuthKey.p8"
```

Create `~/Library/Application Support/Herdr Companion Notifications/config.json` with mode `0600`:

```json
{
  "team_id": "YOUR_TEAM_ID",
  "key_id": "YOUR_APNS_KEY_ID",
  "topic": "com.elysium.herdrcompanion",
  "private_key_path": "/Users/YOU/Library/Application Support/Herdr Companion Notifications/AuthKey.p8"
}
```

Replace every placeholder before loading the helper. None of these values is supplied by this repository, and the helper does not read Apple accounts, keychains, or Developer portal credentials:

| Field | Replace with |
| --- | --- |
| `YOUR_TEAM_ID` | Your 10-character Apple Developer Team ID (letters and digits only; underscores are not valid). |
| `YOUR_APNS_KEY_ID` | The Key ID shown in the Apple Developer portal for that token-signing key. |
| `com.elysium.herdrcompanion` | Keep this APNs topic unless you changed `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml`. If you fork under your own unique bundle ID, use that same identifier here. |
| `/Users/YOU/.../AuthKey.p8` | The absolute path to the `.p8` you copied. Expand `YOU` to the Mac account that owns the helper, or substitute `$HOME` after expanding it. |
| `AuthKey_KEYID.p8` in the copy command | The downloaded filename from Apple, whose `KEYID` matches `YOUR_APNS_KEY_ID`. |

Confirm ownership and modes before loading the service:

```bash
chmod 700 "$HOME/Library/Application Support/Herdr Companion Notifications"
chmod 700 "$HOME/Library/Application Support/Herdr Companion Notifications/bin"
chmod 700 "$HOME/Library/Application Support/Herdr Companion Notifications/bin/herdr-notification-helper"
chmod 600 "$HOME/Library/Application Support/Herdr Companion Notifications/config.json"
chmod 600 "$HOME/Library/Application Support/Herdr Companion Notifications/AuthKey.p8"
printf '%s\n' '{"version":1,"operation":"status"}' | "$HOME/Library/Application Support/Herdr Companion Notifications/bin/herdr-notification-helper" rpc
```

The status response must be `ready`. `unconfigured` or `configuration_invalid` is an actionable failure; do not load the agent until it is corrected.

## 4. Load the per-user agent

Copy `support/com.elysium.herdr-notification-helper.plist` to `~/Library/LaunchAgents/`, replacing `__HELPER_PATH__`, `__HOME__`, and `__XDG_CONFIG_HOME__` with absolute paths for that Mac. The default config root is `/Users/YOU/.config`; use the actual `XDG_CONFIG_HOME` when official Herdr is configured elsewhere.

Then load and inspect it:

```bash
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.elysium.herdr-notification-helper.plist"
launchctl print "gui/$(id -u)/com.elysium.herdr-notification-helper"
```

The helper watches each registered official Herdr session’s local JSON socket. It reconnects with bounded backoff if the socket or event stream is temporarily unavailable.

## 5. Enable a device

Connect to the saved Mac in Herdr Companion, open the bell-shaped Notifications screen, and turn on **Notifications**. The iOS permission prompt is requested only from this explicit action. “Needs your attention” defaults on; “Finished responding” defaults off. Workspace mutes and later preference changes stay pending until the Mac acknowledges them.

Use **Send Test Notification** only on a signed physical device after the screen says **Connected and enabled**. Success means APNs accepted the real request; delivery can still be affected by device/network policy. A local synthetic notification is never reported as a real push.

## Verification checklist

- Initial idle or already-blocked agents do not flood a newly installed device.
- A fresh transition to blocked produces one generic attention notification.
- Repeated event callbacks, helper restart, and reconnect do not duplicate it.
- A later working-to-blocked cycle can notify again.
- Finished alerts appear only when explicitly enabled and only after a live working-to-idle/done transition.
- Disconnecting, deleting a pane, losing the network, or reconnecting to idle never says “Finished responding.”
- Muting one workspace stops that workspace after acknowledgement without suppressing other workspaces.
- Each registered iPhone or iPad receives one event; duplicate routes for one physical token do not duplicate it.
- Rotating a device token updates the helper after reconnect; an APNs-invalid token is removed.
- Revoking permission in iOS Settings removes the active Mac route on the next connection/foreground reconciliation while retaining the requested setting; granting it again resumes APNs registration without another permission prompt.
- A cold-launch tap opens only a fresh route whose saved host and exact current official agent instance can be verified. A stale/mismatched route, replacement agent, or leftover shell remains in the safe roster instead.

## Disable and uninstall

Turn notifications off for every saved Mac in the app while connected and wait for **Disabled**. Deleting a saved host also unregisters its route first; if the Mac cannot acknowledge, deletion remains pending rather than silently leaving a sender behind.

To remove the helper after routes are disabled:

```bash
launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.elysium.herdr-notification-helper.plist"
trash "$HOME/Library/LaunchAgents/com.elysium.herdr-notification-helper.plist"
trash "$HOME/Library/Application Support/Herdr Companion Notifications"
```

The trashed application-support directory contains registrations, deduplication state, configuration, and any signing key placed there. It is recoverable from Trash until emptied. Removing the helper before acknowledged device disable can leave APNs tokens only in the trashed state file; it cannot continue sending once the process and credentials are removed.
