# Polaris

Your Polestar, in the menu bar.

Polaris is a tiny native macOS app that shows your Polestar's battery, range,
and charging status in the menu bar. Pure AppKit — no Electron, no SwiftUI,
no background services. It talks only to Polestar's official API.

Sibling project of [Teslaris](https://github.com/simonbusborg/teslaris)
(the same app for Tesla).

**[Download the latest release](https://github.com/simonbusborg/polaris/releases/latest)** · [Website](https://simonbusborg.github.io/polaris/)

## Features

- Battery %, range (km/mi), charging status and time-to-full — refreshed every
  5 minutes, or every minute while charging
- Notifications when charging starts, completes, or the charger reports a fault
- Choose what the menu bar shows
- Password and session stored in the macOS Keychain — never in plaintext, and
  the session is resumed on launch instead of logging in again
- OAuth2/OIDC with PKCE against Polestar's official endpoints; no third parties, no analytics, no tracking
- A once-a-day update check against GitHub releases (a menu item appears when
  there's a new version — nothing is downloaded automatically)
- Launch at login (optional)
- A single small binary

## Install

Download `Polaris.dmg` from the [latest release](https://github.com/simonbusborg/polaris/releases/latest),
open it, and drag Polaris to Applications (a `Polaris.zip` is also
attached for scripted installs). Releases are built by GitHub Actions.
macOS blocks the first launch of unsigned releases ("Apple could not
verify…"): click **Done**, then **System Settings → Privacy & Security →
Open Anyway**. On macOS 14 and earlier, **right-click → Open → Open**
also works. This happens once.

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

Tag a version and push — GitHub Actions builds the app and attaches `Polaris.zip`
to the release automatically:

```bash
git tag v1.0.0
git push origin v1.0.0
```

Releases are signed and notarized when these repository secrets are configured
(without them the workflow falls back to an ad-hoc-signed build):

| Secret | Value |
| --- | --- |
| `MACOS_CERT_P12` | Base64 of a "Developer ID Application" certificate + private key (`.p12`) |
| `MACOS_CERT_PASSWORD` | Password of that `.p12` |
| `NOTARY_APPLE_ID` | Apple ID email used for notarization |
| `NOTARY_TEAM_ID` | 10-character Apple Developer Team ID |
| `NOTARY_APP_PASSWORD` | App-specific password for that Apple ID |

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
