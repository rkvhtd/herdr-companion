<p align="center">
  <img src="docs/images/cover.png" alt="Decorative illustration for Herdr Companion. Limestone title on charcoal, a branching cream form ending in a vermilion terminal key, and the line Your Mac terminals, on iPhone and iPad. Not a screenshot of the app." width="100%">
</p>

# Herdr Companion

Control the [Herdr](https://herdr.dev) workspace on your Mac from iPhone or
iPad: see what needs you, open the workspace, tab, and pane, and work in
the live terminal.

It uses SSH you already have on the LAN or a VPN/mesh (Tailscale and
similar are fine). No Herdr cloud account, relay, or telemetry.
Unofficial open-source client from Elysium Technologies; official Herdr
is unchanged.

[Install](#install) · [Connect](#connect) · [Limits](#limits) · [Notifications](#optional-notifications) · [Credits](#credits)

## Screenshots

The real app, with demo data. Not a live SSH session.

<p>
  <img src="docs/images/phone-overview.png" alt="iPhone demo of the Desk, connected to Example Mac. Attention lists reviewer needing you, mystery-bot with unknown status, and two running agents." width="320">
  <img src="docs/images/phone-workspace.png" alt="iPhone demo of the Companion App workspace. The review tab shows Codex, Claude, and Gemini agents; the shell tab shows a zsh pane." width="320">
</p>

<details>
<summary>See the iPad layout</summary>

<p>
  <img src="docs/images/ipad-workspace.png" alt="iPad demo of the Companion App workspace on a larger layout, with review and shell tabs and the same synthetic agent panes." width="720">
</p>

</details>

See [docs/images/ATTRIBUTION.md](docs/images/ATTRIBUTION.md) for what these
files are.

## Away from the desk

The Desk is the first screen. Agents that need you sit at the top, then
the ones still running, then idle. Unknown status stays on the list
rather than disappearing.

From there, open a workspace Herdr already has. Pick the tab, then the
pane, and attach when you want to type. You are in the live terminal:
answer the agent, run the next command, or read what already happened.

To start another shell, create a workspace, a terminal tab, or a split,
and give it an existing folder. The app does not invent a path from
whatever the Mac currently has focused, and it does not create folders.

An image can be handed to the terminal as a path. Upload is images only,
into a private app-owned directory on that Mac. The path is inserted only
after you tap. Insertion does not send Return.

## Install

```bash
git clone https://github.com/rkvhtd/herdr-companion.git
cd herdr-companion
```

You need Xcode 26.5 and XcodeGen 2.46 or newer. The app target is iOS 17.
The Xcode project is generated from [`project.yml`](project.yml) and is
not committed. `DEVELOPMENT_TEAM` is left empty. There is no App Store or
TestFlight build.

Tested against official Herdr **0.9.0** (protocol **22**). Newer releases
are not claimed compatible.

On the Mac:

```bash
herdr --version
herdr status server
```

The usual session name is `default`. A named session can be selected on a
saved host; the same session is used for the JSON control socket and
terminal attachment.

### Simulator

A simulator run does not need an Apple Developer team.

```bash
xcodegen generate
open HerdrCompanion.xcodeproj
```

In Xcode, select the HerdrCompanion scheme and a simulator, then Run.

An unsigned command-line build is under [Development](#development).

A physical device needs a paid Apple Developer Program team whose App ID
includes Push Notifications, even if you never turn on alerts. A free
Personal Team cannot provision this unchanged entitlement.

<details>
<summary>Physical device: change all three bundle identifiers first</summary>

The committed app identifier is `com.elysium.herdrcompanion`. That App ID
belongs to the publisher. If you are not signing with the publisher's Apple
team, change all three `PRODUCT_BUNDLE_IDENTIFIER` values in
[`project.yml`](project.yml) to unique identifiers your team controls
before you run `xcodegen generate`. Those settings are:

| Target | `PRODUCT_BUNDLE_IDENTIFIER` today | Example replacement |
| --- | --- | --- |
| HerdrCompanion | `com.elysium.herdrcompanion` | `com.example.herdrcompanion` |
| HerdrCompanionTests | `com.elysium.herdrcompanion.tests` | `com.example.herdrcompanion.tests` |
| HerdrCompanionUITests | `com.elysium.herdrcompanion.uitests` | `com.example.herdrcompanion.uitests` |

Use your own reverse-DNS names, not `com.example` and not the publisher IDs.
Do this for a fresh clone as well as a fork.

Then generate and open:

```bash
xcodegen generate
open HerdrCompanion.xcodeproj
```

Select the HerdrCompanion scheme, choose your Apple Developer team, keep
automatic signing, connect and select your device, and Run.

If you edit `project.yml` after generating, run `xcodegen generate` again.
Signing choices made only in Xcode are not stored in `project.yml`; a later
generate can overwrite them. Keep identifier changes in `project.yml` so they
survive regeneration.

The current device target always requests the `aps-environment` entitlement,
so the App ID and provisioning profile for a physical device need the Push
Notifications capability even if you never turn on alerts. A profile without
that capability can fail signing or provisioning before the app launches.
Runtime notification use remains optional. Debug uses the APNs `development`
environment; Release uses `production`. Real APNs delivery is not verified
by the tests in this repository.

The current device target requires an Apple Developer Program team with Push
Notifications support. A free Personal Team cannot provision this unchanged
entitlement. See Apple's [supported capabilities for iOS](https://developer.apple.com/help/account/reference/supported-capabilities-ios).

Do not reuse another publisher's team or App ID.

</details>

## Connect

1. Save a nickname, SSH address (`host` or `host:port`), username, Herdr
   session, and either a private key or a password. Secrets stay in the
   device Keychain.
2. Connect. The first successful host key is pinned. A later mismatch needs an explicit confirmation.
3. Browse workspaces, tabs, and panes, or open an agent from the Desk.
4. Attach to a pane when you want the live terminal. Agent panes use
   `herdr agent attach`; plain panes use `herdr terminal attach`.

The phone or iPad only needs to reach that Mac's SSH the same way you
already would from another machine on your network. Keep port 22 off the
public internet. Connection failures are shown; credentials are not written
to logs.

## Limits

The app does not create agents, and it does not rename or close workspaces,
tabs, or panes. It is not a remote file browser, it will not create
folders, and only images can be uploaded. It does not switch VPNs, manage
the Herdr server, migrate sessions, or use fork-only messaging APIs. There
is no App Store or TestFlight build.

## Optional notifications

Alerts are optional and self-hosted. Sending them needs a physical iPhone
or iPad, an APNs token-signing key, and a helper on every saved Mac that
should send those alerts. Simulator builds check UI and routing. They are
not evidence of a real APNs delivery.

Setup: [docs/notifications-setup.md](docs/notifications-setup.md).
Protocol: [docs/notifications-protocol.md](docs/notifications-protocol.md).

Helper installation copies only paths you supply. It does not search for
Apple accounts or keys.

## Development

Issues and pull requests for defects in the published sources are welcome.

<details>
<summary>Unsigned simulator build and package tests</summary>

The Xcode project is generated and is not committed.

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

Optional Mac helper, only if you want notifications later:

```bash
swift build -c release --product herdr-notification-helper
```

Safe default package tests do not use workstation SSH keys, the default
Herdr session, or port 22:

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

</details>

## Credits

Derived from [Herdrup](https://github.com/jerryfane/herdrup) at commit
[`93c6578666e656c3206661389e81853bcc0b88da`](https://github.com/jerryfane/herdrup/commit/93c6578666e656c3206661389e81853bcc0b88da)
([Apache-2.0](https://github.com/jerryfane/herdrup/blob/93c6578/LICENSE)).
The iOS shell, optional notification helper, and related tests are Companion
work on top of that baseline. The protocol layer is retained and modified.
Vendored SwiftTerm is unchanged in origin.

Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE) (including SwiftTerm,
Geist, and IBM Plex Mono). App icon replacement provenance is in
[App/Assets.xcassets/ATTRIBUTION.md](App/Assets.xcassets/ATTRIBUTION.md).
Landing images are described in
[docs/images/ATTRIBUTION.md](docs/images/ATTRIBUTION.md).

## Security reports

Do not put private keys, pairing codes, device tokens, `.p8` files,
passwords, or someone else's host names into public issues. This repository
does not publish a dedicated vulnerability inbox. Describe a bug without
attaching secrets.
