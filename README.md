# Herdr Companion

Modified from [Herdrup](https://github.com/jerryfane/herdrup) commit
[`93c6578666e656c3206661389e81853bcc0b88da`](https://github.com/jerryfane/herdrup/commit/93c6578666e656c3206661389e81853bcc0b88da)
by Elysium Technologies.

Unofficial iPhone and iPad client for a [Herdr](https://herdr.dev) server running
on your Mac. It connects over SSH to that Mac. There is no Herdr relay, cloud
account, or telemetry.

This is **not** official Herdr. It is published by Elysium Technologies as a
personal open-source project named `herdr-companion`. The iOS bundle identifier
is `com.elysium.herdrcompanion`. Official Herdr remains unchanged.

## Origin

Derived from [Herdrup](https://github.com/jerryfane/herdrup) at commit
[`93c6578`](https://github.com/jerryfane/herdrup/commit/93c6578)
([Apache-2.0](https://github.com/jerryfane/herdrup/blob/93c6578/LICENSE)).
Companion-specific sources live mainly in `App/`,
`Sources/HerdrNotificationHelper`, `Sources/HerdrNotificationHelperCore`,
`Tests/HerdrCompanionTests`, `Tests/HerdrCompanionUITests`, and
`Tests/HerdrNotificationHelperTests`. They replace the inherited Herdrup iOS
shell with a narrower official-Herdr workflow: saved SSH hosts, workspace
browsing and creation, plain terminal tabs and splits, a grouped agent overview,
and interactive terminal attachment. `Sources/HerdrKit` is the retained and
modified protocol/transport layer. Vendored SwiftTerm is unchanged in origin.

## Requirements

Tested against official Herdr **0.9.0** (protocol **22**). Newer Herdr releases
are not claimed compatible.

- A Mac running that Herdr version, with SSH reachable from the iPhone or iPad.
- A VPN path is optional and outside this app. A Tailscale name or similar
  mesh address works if the device can already reach the Mac.
- Xcode 26.5 and XcodeGen 2.46 or newer to generate and compile this checkout.

On the Mac:

```bash
herdr --version
herdr status server
```

The standard session name is `default`. A named session can be selected on a
saved host; the same session is used for the JSON control socket and terminal
attachment.

## Build from a fresh clone

The Xcode project is generated and is not committed. `project.yml` leaves
`DEVELOPMENT_TEAM` empty. Signing stays on the local machine.

```bash
xcodegen generate

xcodebuild \
  -project HerdrCompanion.xcodeproj \
  -scheme HerdrCompanion \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$PWD/.derivedData" \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Optional Mac helper (only if you want notifications later):

```bash
swift build -c release --product herdr-notification-helper
```

If you fork this project, choose your own unique bundle identifiers and Apple
team. Do not reuse another publisher's team or App ID.

## Physical-device signing

No developer team or provisioning profile is committed. Generate the project,
open `HerdrCompanion.xcodeproj`, and select **your** Apple Developer team for
the **HerdrCompanion** target.

The current target always requests the `aps-environment` entitlement, so every
physical-device build needs a matching push-capable App ID and provisioning
profile. A profile without that capability can fail signing or provisioning
before the app launches, even if you do not intend to use notifications.
Runtime notification use remains optional. Debug uses the APNs `development`
environment; Release uses `production`. Real APNs delivery is not verified by
the tests in this repository. Helper installation copies only paths you supply;
it does not search for Apple accounts or keys. See
[docs/notifications-setup.md](docs/notifications-setup.md) and
[docs/notifications-protocol.md](docs/notifications-protocol.md).

## Use

1. Save a nickname, SSH address, username, Herdr session, and either a private
   key or a password. Secrets stay in the device Keychain.
2. Connect. The first successful host key is pinned; a later mismatch requires
   explicit confirmation.
3. Browse workspaces, tabs, and panes. Create a workspace, terminal tab, or
   split with an explicit folder. The companion does not use Mac focus to choose
   a folder.
4. Attach to a pane. Agent panes use `herdr agent attach`; plain panes use
   `herdr terminal attach`. Both run in a dedicated SSH PTY.
5. Optional image attach uploads to a private app-owned directory on that Mac
   and inserts the path only after an explicit tap. Insertion does not send
   Return.

Connection failures are shown without logging credentials.

## Supported scope and limits

Included: saved SSH hosts, host-key pinning, official topology, workspace/tab
split creation, official terminal attachment, optional self-hosted APNs helper.

Not included: creating agents; closing or renaming workspaces/tabs/panes;
arbitrary remote file browsing; automatic folder creation; non-image uploads;
VPN switching; server account or update management; session migration;
fork-only messaging APIs; App Store or TestFlight distribution.

## Tests

Safe default package tests do not use workstation SSH keys, the default Herdr
session, or port 22:

```bash
swift test --filter OfficialCompanionTests
swift test --filter LiveEnvironmentTests
swift test --filter CitadelTransportTests \
  --skip CitadelTransportTests/testConnectFailsWithinTheBudgetAgainstABlackHoleAddress
```

`HerdrCompanionTests` is in the generated Xcode scheme and covers connection
generation, cancellation, mutation failures, and host-key recovery.

Live SSH/Herdr tests require an explicit disposable fixture
(`HERDR_COMPANION_LIVE_SSH=1` or `HERDR_COMPANION_INTEGRATION=1` plus isolated
`HERDR_COMPANION_FIXTURE_*` values). They refuse port 22, non-loopback hosts,
the default session, and keys outside
`/private/tmp/herdr-companion-ssh-fixture.*`. Do not point them at a personal
Mac.

## Contributing

This is a bounded personal project. Issues and pull requests for defects in the
published sources are welcome. There is no support SLA, roadmap promise,
sponsorship program, or hosted extra service.

## Security reports

Do not put private keys, pairing codes, device tokens, `.p8` files, passwords,
or someone else's host names into public issues. This repository does not
publish a dedicated vulnerability inbox. Describe a bug without attaching
secrets.

## License and credits

Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE). App icon replacement
provenance is in [App/Assets.xcassets/ATTRIBUTION.md](App/Assets.xcassets/ATTRIBUTION.md).
