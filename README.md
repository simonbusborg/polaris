# Polaris

Your Polestar, in the menu bar.

Polaris is a tiny native macOS app that shows your Polestar's battery, range,
and charging status in the menu bar. Pure AppKit — no Electron, no SwiftUI,
no background services. It talks only to Polestar's official API.

Sibling project of [Teslaris](https://github.com/simonbusborg/teslaris)
(the same app for Tesla).

[![Downloads](https://img.shields.io/github/downloads/simonbusborg/polaris/total?label=downloads&color=blue)](https://github.com/simonbusborg/polaris/releases)

**[Download Polaris.dmg](https://github.com/simonbusborg/polaris/releases/latest/download/Polaris.dmg)** · [All releases](https://github.com/simonbusborg/polaris/releases) · [Website](https://simonbusborg.github.io/polaris/)

## Features

- Battery %, range (km/mi), charging status and time-to-full — refreshed every
  5 minutes, or every minute while charging
- Charger connection, live charging power and whether it's AC or DC, read from
  the gRPC battery service the GraphQL API doesn't cover
- Odometer, service interval and fluid warnings
- Notifications when charging starts, completes, or the charger reports a fault
- Choose what the menu bar shows
- Follows the system language: English, Danish, Swedish, Norwegian, German,
  Spanish and Italian. Adding one is a single `Resources/<lang>.lproj/Localizable.strings`
  file; a test fails the build if any language falls behind the others
- Password and session stored in the macOS Keychain — never in plaintext, and
  the session is resumed on launch instead of logging in again
- OAuth2/OIDC with PKCE against Polestar's official endpoints; no third parties, no analytics, no tracking
- A once-a-day update check against GitHub releases (a menu item appears when
  there's a new version — nothing is downloaded automatically)
- Launch at login (optional)
- A single small binary

See [ROADMAP.md](ROADMAP.md) for what's planned, what's shipped, and what
deliberately isn't happening.

## Install

Download `Polaris.dmg` from the [latest release](https://github.com/simonbusborg/polaris/releases/latest),
open it, and drag Polaris to Applications (a `Polaris.zip` is also
attached for scripted installs). Releases are built by GitHub Actions,
signed with a Developer ID and notarized by Apple, so it opens like any
other app — no security warning to click past.

Then click the menu bar icon → Settings… → enter your Polestar email, password,
and VIN.

## Build from source

Requires macOS 13+ and the Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/simonbusborg/polaris
cd polaris
make app
open Polaris.app
```

`make run` builds and runs the bare binary for quick iteration (launch-at-login
and notifications are unavailable in that mode). `make test` (or `swift test`)
runs the test suite.

## Releasing

One command from a clean working tree — it bumps `Info.plist`, commits, tags
and pushes, and GitHub Actions builds the app and attaches `Polaris.dmg` and
`Polaris.zip` to the release:

```bash
make release VERSION=1.0.0
```

Don't tag by hand. The release workflow checks the tag against
`CFBundleShortVersionString` and fails if they disagree, because the update
checker compares the two — a release whose plist says something else would nag
every user forever. `make release` bumps the plist as part of the same commit,
which is what keeps them in step.

Releases are signed and notarized when these repository secrets are configured
(without them the workflow falls back to an ad-hoc-signed build):

| Secret | Value |
| --- | --- |
| `MACOS_CERT_P12` | Base64 of a "Developer ID Application" certificate + private key (`.p12`) |
| `MACOS_CERT_PASSWORD` | Password of that `.p12` |
| `NOTARY_APPLE_ID` | Apple ID email used for notarization |
| `NOTARY_TEAM_ID` | 10-character Apple Developer Team ID |
| `NOTARY_APP_PASSWORD` | App-specific password for that Apple ID |

## Debug flags

Off by default, and none of them alter what the API returns:

```bash
defaults write com.weareheavy.polaris debug_grpc_fields -bool YES
defaults delete com.weareheavy.polaris debug_grpc_fields   # turn it off again
```

| Key | Effect |
| --- | --- |
| `debug_grpc_fields` | Logs which fields the battery message actually carries (`log show --info --last 10m \| grep "battery fields"`). Field numbers and numeric values only — no VIN, no raw payload |
| `debug_pno34` | Shows the car's raw `pno34` product code as a copyable menu row. This is how a code gets read off a real car to fill in `PNO34.variantsByPrefix` |
| `debug_charging_type` | A string (`AC`, `DC`, `WIRELESS`) that renders the charging rows on a parked car. It invents its numbers in the menu layer, so it demonstrates the layout and nothing about the wire format — and it hides the real Power row while set |
| `debug_demo_car` | Adds a pretend second car mirroring the real one, so the multi-car switcher can be exercised on a single-car account |

Not every field the battery service documents is actually sent. A 2026
Polestar 4 reports no average consumption at all, which is why there's no row
for it; `debug_grpc_fields` is how that kind of question gets settled.

## Credits

The Polestar auth/API flow was originally studied from
[Michiel1992/voltstarP](https://github.com/Michiel1992/voltstarP) and updated to
Polestar's current login flow and GraphQL schema (with reference to
[pypolestar](https://github.com/pypolestar/pypolestar)). Polaris is a from-scratch
AppKit implementation.

## Disclaimer

Not affiliated with Polestar. Use at your own risk.

## License

[MIT](LICENSE)
