# Agent setup

This is a setup runbook for Herdr Companion, not a global `AGENTS.md`.

Paste this to an agent. Fill placeholders you already know; leave the rest
blank. The README uses the same text.

```
Read https://github.com/rkvhtd/herdr-companion/blob/main/AGENT_SETUP.md and follow it in this environment.

Target: [Simulator | iPhone | iPad]
Device name: [if physical]
Checkout: [existing path or clone destination]
Apple team / bundle prefix: [physical device only]
Mac SSH: [nickname, host or host:port, username, Herdr session]
Auth method: [private key | password; never include the secret]
```

Ask only for missing target and device, checkout location, Apple team and
bundle prefix on a physical device, and Mac SSH/session details that cannot
be inferred (auth method only, never the secret). Honor authorizations
already given; do not re-ask for every reversible step. SSH passwords, key
passphrases, private-key contents, Apple passwords, and 2FA codes must never
be supplied in chat or logs. Enter connection secrets locally in the app.
Never impersonate a permission, Developer Mode, device-trust, or signing tap.

Minimum deployment target: iOS 17. Documented toolchain: Xcode 26.5 and
XcodeGen 2.46. Tested against official Herdr 0.9.0 (protocol 22). Newer
Xcode or Herdr is unclaimed. HerdrKit requires macOS 14. There is no App
Store or TestFlight build. The agent can preflight, clone or inspect,
generate the Xcode project, do the unsigned simulator build, edit local
bundle IDs, open the HerdrCompanion scheme, inspect an already running
official Herdr session, and save connection fields the user supplies. Stop
for Apple account, 2FA, unlock, trust, Developer Mode, Remote Login, or a
permission prompt. Do not disable host-key checks, strip the push
entitlement, force signing, or expand scope.

## 1. Preflight

Read-only checks on the Mac:

```bash
sw_vers
xcode-select -p
xcodebuild -version
xcrun --find xcodebuild
xcodebuild -showsdks
command -v xcodegen && xcodegen --version
```

Expect a full Xcode 26.5 developer directory (commonly
`/Applications/Xcode.app/Contents/Developer`), not Command Line Tools alone,
and XcodeGen 2.46 or newer. Simulator route also needs an iOS Simulator SDK.
If Xcode is missing or too old, stop: install Xcode 26.5 from Apple, accept
the license, and point `xcode-select` at it. Do not run `sudo` or upgrade
Xcode unless the user asked. If `xcodegen` is missing, stop and ask how they
install Mac tools. Homebrew users can run `brew install xcodegen`, then
confirm `xcodegen --version` is 2.46 or newer; the formula is unpinned. No
curl-pipe-shell, and no unsolicited global upgrades.

## 2. Checkout

Public repo: `https://github.com/rkvhtd/herdr-companion.git`.

If Checkout is empty, ask where to clone. Resolve the answer to an absolute
path and assign `CHECKOUT` to that path before running either block below.
Do not run the examples with a placeholder still in `CHECKOUT`.

New clone, only when that path is not already the repo:

```bash
: "${CHECKOUT:?set CHECKOUT to the chosen absolute destination first}"
git clone https://github.com/rkvhtd/herdr-companion.git "$CHECKOUT"
cd "$CHECKOUT"
git rev-parse HEAD
git status
git remote -v
```

Existing checkout: inspect that tree. Do not clone onto it, and do not
reset, clean, or overwrite local changes.

```bash
: "${CHECKOUT:?set CHECKOUT to the existing absolute checkout first}"
cd "$CHECKOUT"
git rev-parse HEAD
git status
git remote -v
```

Record the commit. If the tree is dirty, keep those changes and say what
drifted. Do not `git pull` over modifications. Respect local repo
instructions.

## 3. Simulator or physical device

Use the stated Target. Simulator needs no Apple team. Physical iPhone or
iPad needs a paid Apple Developer Program team and unique bundle identifiers
the user owns. The Xcode project is generated from
[`project.yml`](project.yml) and is not committed. `DEVELOPMENT_TEAM` stays
empty; pick the team in Xcode. Signing chosen only in Xcode can be
overwritten by a later `xcodegen generate`. Keep identifier changes in
`project.yml`.

### Physical device identifiers

The committed app identifier `com.elysium.herdrcompanion` belongs to the
publisher. Bundle identifiers are public labels, not passwords. Another
team's App ID is not signing authority for your devices, and reusing it can
collide with provisioning or the identifier itself.

Change all three `PRODUCT_BUNDLE_IDENTIFIER` values in `project.yml` to
unique reverse-DNS names the user's team controls. Keep the `.tests` and
`.uitests` suffixes relative to the app ID:

| Target | Committed value | Example replacement |
| --- | --- | --- |
| HerdrCompanion | `com.elysium.herdrcompanion` | `com.yourname.herdrcompanion` |
| HerdrCompanionTests | `com.elysium.herdrcompanion.tests` | `com.yourname.herdrcompanion.tests` |
| HerdrCompanionUITests | `com.elysium.herdrcompanion.uitests` | `com.yourname.herdrcompanion.uitests` |

Do not keep the publisher IDs and do not use `com.example`. Register the app
ID on the user's team if needed
([Register an App ID](https://developer.apple.com/help/account/identifiers/register-an-app-id/);
[Changing the bundle identifier](https://developer.apple.com/documentation/xcode/changing-the-bundle-identifier)).

The device target always requests `aps-environment` (Debug `development`,
Release `production`). The App ID and profile must include Push
Notifications even if alerts stay off. A free Personal Team cannot provision
this unchanged entitlement. Do not strip the entitlement or change app
capabilities to dodge that. See
[supported capabilities for iOS](https://developer.apple.com/help/account/reference/supported-capabilities-ios).

Keep identity changes local. Do not upload credentials, profiles, or `.p8` /
`.p12` files.

## 4. Generate and build

```bash
xcodegen generate
open HerdrCompanion.xcodeproj
```

Select the HerdrCompanion scheme.

### Simulator

Select a simulator and Run. Unsigned command-line build (no team, no device
install):

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

Product: `.derivedData/Build/Products/Debug-iphonesimulator/Herdr Companion.app`
(gitignored). This build is not a live SSH session.

### Physical iPhone or iPad

Select the user's Apple team, keep automatic signing, connect the named
device, unlock it, and Run. Trust the computer and enable Developer Mode
when iOS asks; those taps are human-only. Do not promise unattended
provisioning. If signing or Push fails, stop and use the table below.

Optional CLI install after a signed device build. Prefer Xcode Run. This
documentation did not test a physical install. If you use `devicectl`, list
devices and pass the identifier the user selected, never the first row:

```bash
xcrun devicectl list devices
xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH"
```

`$DEVICE_ID` is the user-selected identifier, UDID, serial, or name, never
the first listed device. `$APP_PATH` is the signed device `.app`, not the
unsigned simulator product.

## 5. Optional synthetic preview

Only if useful, DEBUG Run only. HerdrCompanion scheme launch argument:

```
--companion-visual-fixture=overview
```

Fake data: not SSH, not a saved host, not proof of a Mac connection. Remove
it before a real connect. Skip extra simulator scripting when Xcode Run is
enough.

## 6. Connect to the Mac

Official Herdr must be installed and running on the intended Mac. Bind
`HERDR_SESSION` to the session the user selected for this saved host
(`default` if they did not name another). Do not inspect a different
session this agent happens to be using.

```bash
: "${HERDR_SESSION:?set HERDR_SESSION to the session selected for this Mac first}"
herdr --version
herdr --session "$HERDR_SESSION" status server
```

The same session is used for the JSON control socket and terminal
attachment. On that Mac the socket root (`CONFIG_ROOT`) is
`${XDG_CONFIG_HOME:-$HOME/.config}`. `default` uses
`$CONFIG_ROOT/herdr/herdr.sock`. Other names use
`$CONFIG_ROOT/herdr/sessions/<name>/herdr.sock`. Names are 1–64 bytes of
ASCII letters, digits, `.`, `_`, or `-`, except `.` and `..`.

Reuse LAN, VPN, or mesh reachability the user already has. Enable macOS
Remote Login only with their authorization, and only if it is not already
on. Keep port 22 off the public internet.

In the app, save nickname, SSH address (`host` or `host:port`), username,
Herdr session, and a private key or password. Secrets stay in the device
Keychain. Blank port is 22. Type the secret on the device; never put an SSH
password, key passphrase, or private key in chat. `localhost` / `127.0.0.1`
on a physical phone is the phone, not the Mac. The iOS Simulator on the same
Mac can use localhost when Remote Login is on.

Connect. The first successful host key is pinned. A later mismatch shows
the old pinned identity and a newly presented identity; those two values
are supposed to differ. Independently verify the presented fingerprint
against the intended Mac's current host key over a trusted channel before
accepting. The dialog fingerprints are not enough by themselves. Do not
bypass a mismatch or disable host-key checks.

From the Desk, open a workspace Herdr already has, pick the tab, then the
pane, and attach. Agent panes use `herdr agent attach`; plain panes use
`herdr terminal attach`. Opening a pane is not proof that send and receive
both work. The app does not create agents. It creates a workspace, terminal
tab, or split only if the user asks, and only into an existing folder. Do
not create or delete panes or change the Herdr server to verify setup. Do
not point this repository's live SSH tests at a personal Mac, workstation
keys, the default session, or port 22.

## 7. Success

Done when the app builds and installs on the selected target; connects to
the intended Mac and Herdr session; lists a workspace that already existed;
opens the intended live pane; and, in a known plain shell (not an agent
pane) and only with the user's say-so, a harmless command such as `date` is
sent and the echo or result is visible. A simulator demo, including the
synthetic fixture, is not an actual SSH session.

## 8. Troubleshooting

| Problem | What to do |
| --- | --- |
| `xcode-select` is Command Line Tools, or `xcodebuild` missing | Install Xcode 26.5 and switch the developer directory. Do not guess a path. |
| No iOS Simulator SDK / runtime | Install the iOS platform in Xcode Settings. Do not boot random simulators. |
| `xcodegen` missing or old | Ask before installing. After Homebrew, verify `xcodegen --version` is 2.46 or newer. Do not upgrade globals unasked. |
| Bundle ID, team, or provisioning fails | All three identifiers must be unique and user-owned. Pick the user's paid team in Xcode. Generate again after `project.yml` edits. |
| Push / `aps-environment` | App ID needs Push Notifications. Personal Team cannot provision this target unchanged. Do not strip the entitlement. |
| Device locked, untrusted, or Developer Mode off | Human unlocks, trusts the computer, and enables Developer Mode. Stop there. |
| Cannot reach SSH | Use the same host:port that already works from another machine. A phone's localhost is the phone. |
| Auth failed | User re-enters the key or password in the app. Do not dump credentials or `~/.ssh`. |
| Host key changed | The pinned and presented values are supposed to differ. Verify the presented fingerprint against the Mac's current key over a trusted channel before accepting. Never skip the check. |
| Empty session, wrong session, or protocol errors | Bind `HERDR_SESSION` to the selected name and run `herdr --session "$HERDR_SESSION" status server` on that Mac. Names: 1–64 bytes, ASCII letters/digits/`.`/`_`/`-`, not `.` or `..`. Tested: Herdr 0.9.0, protocol 22. Newer is unclaimed. |
| Remote socket missing | Same bound `herdr --session "$HERDR_SESSION" status server`. Socket root `${XDG_CONFIG_HOME:-$HOME/.config}`; `default` is `$CONFIG_ROOT/herdr/herdr.sock`, named is `$CONFIG_ROOT/herdr/sessions/<name>/herdr.sock`. |

No broad reset, forced signing, permission bypass, or silent scope change.

## 9. Optional notifications

Skip for basic setup. Simulator and package tests are not real APNs
delivery. A separate explicit request may follow
[docs/notifications-setup.md](docs/notifications-setup.md), including that
guide's own authorization requirements. Do not install LaunchAgents, copy
`.p8` keys, or send test pushes as part of basic setup.

## 10. Handoff

Report checkout path and `git rev-parse HEAD`; Simulator vs named physical
device; whether the unsigned simulator build, Xcode Run, and/or a real SSH
session succeeded; local edits (usually `project.yml` identifiers); any
human step still open; cleanup limited to caches this task created (for
example `$PWD/.derivedData`). Leave the checkout, app, user data, and other
devices alone. Do not `git push` or publish. Do not delete simulators or
profiles you did not create.
