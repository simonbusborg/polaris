# Roadmap

What's planned for Polaris, roughly in the order it's likely to happen.
Nothing here is a promise with a date attached — it's a single developer and
a car API that isn't documented for third parties.

Each item links to an issue. Comment there if you want it, or if you can
help; that's more useful than a wish sent anywhere else.

## Next

- **Signed and notarized builds** — the app is ad-hoc signed today, which is
  why macOS makes you right-click → Open on first launch. Waiting on an Apple
  Developer account, then this becomes a re-release rather than new code.
- **More languages** — the seven below cover most of Polestar's European
  markets, but not all of them. Dutch, Finnish, French, Portuguese and Polish
  are the obvious next ones. One file per language; translators welcome.
- **A better "in use" signal** — the API's charging status reads `IDLE`
  whether the car is parked or on the motorway, so driving is currently
  inferred from how fresh the odometer reading is. It works, but it can lag
  behind by a refresh cycle after you park.
- **Homebrew cask** — `brew install --cask polaris` instead of downloading a
  DMG and dragging it.

## Being looked at

These depend on what the API actually exposes, which is not something that
can be promised before someone has tried it.

- **Charging history** — a log of recent sessions rather than only what's
  happening right now.
- **Climate / preconditioning status** — whether the car reports it at all is
  still an open question.
- **Multiple accounts** — distinct from multiple cars, which already works.

## Shipped

- **Multiple cars** (v2.2.0) — a switcher appears in the menu when the
  account has more than one car.
- **System language, 7 languages** (unreleased, on `main`) — English, Danish,
  Swedish, Norwegian, German, Spanish and Italian. The app follows the macOS
  language setting; there is no language picker to find.
- **"In use" while driving** (unreleased, on `main`).
- **Notifications** (v2.2.0) — charging started, complete, and charger faults.
- **Charging power, AC/DC and charger connection** (v2.3.0).
- **Update notice** (v2.1.0) — a menu item when a new release exists.

## Not planned

- **Remote commands** (unlock, start charging, climate on) — Polaris is
  read-only by design. A menu bar app that can unlock a car is a different
  and much more careful piece of software.
- **iOS / iPadOS** — this is a macOS menu bar app.
- **Telemetry** — no analytics, no crash reporting, no phoning home.
