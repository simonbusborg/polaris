# Roadmap

What's planned for Polaris, roughly in the order it's likely to happen.
Nothing here is a promise with a date attached — it's a single developer and
a car API that isn't documented for third parties.

Each item links to an issue. Comment there if you want it, or if you can
help; that's more useful than a wish sent anywhere else.

## How issues are worked

An issue is closed by the release that ships it, not by the commit that
writes the code — until it's tagged, nothing is out with users. So:

1. The work lands on `main` and CI goes green.
2. `make release VERSION=x.y.z` tags it and Actions builds the release.
3. Then, on each issue the release closes: a comment saying what actually
   shipped and in which version, and what deliberately didn't — then close it.

Everything public is written in English — issues, comments, releases, this
file. The people asking are from all over Polestar's markets, and a reply in
Danish is a reply only Simon can read.

The comment is the point. A silently closed issue tells the person who asked
nothing, and this roadmap's "Shipped" list is only trustworthy if every entry
has a version next to it. An issue that got *partly* solved stays open with a
comment describing where it now stands.

## Next

- **[In-app updates](https://github.com/simonbusborg/polaris/issues/8)** — "Update now" and an automatic-updates toggle,
  via Sparkle. Today the app only tells you a new version exists and sends you
  to the browser. Now possible because releases are signed.
- **[A better "in use" signal](https://github.com/simonbusborg/polaris/issues/3)** — the API's charging status reads `IDLE`
  whether the car is parked or on the motorway, so driving is currently
  inferred from how fresh the odometer reading is. It works, but it can lag
  behind by a refresh cycle after you park.
- **[Homebrew cask](https://github.com/simonbusborg/polaris/issues/4)** — `brew install --cask polaris` instead of downloading a
  DMG and dragging it.

## Being looked at

These depend on what the API actually exposes, which is not something that
can be promised before someone has tried it.

- **[Charging history](https://github.com/simonbusborg/polaris/issues/5)** — a log of recent sessions rather than only what's
  happening right now.
- **[Climate / preconditioning status](https://github.com/simonbusborg/polaris/issues/6)** — whether the car reports it at all is
  still an open question.
- **[Multiple accounts](https://github.com/simonbusborg/polaris/issues/7)** — distinct from multiple cars, which already works.

## Shipped

- **Signed and notarized builds** (v2.5.1) — releases are signed with a
  Developer ID and notarized by Apple. The first-launch security warning is
  gone.

- **Multiple cars** (v2.2.0) — a switcher appears in the menu when the
  account has more than one car.
- **System language, 12 languages** (v2.5.0, extended in v2.6.0) — English, Danish,
  Swedish, Norwegian, German, Spanish and Italian. The app follows the macOS
  language setting; there is no language picker to find.
- **"In use" while driving** (v2.5.0) — the charging status never says
  "driving", so it's inferred from odometer freshness.
- **Notifications** (v2.2.0) — charging started, complete, and charger faults.
- **Charging power, AC/DC and charger connection** (v2.3.0).
- **Update notice** (v2.1.0) — a menu item when a new release exists.

## Not planned

- **Remote commands** (unlock, start charging, climate on) — Polaris is
  read-only by design. A menu bar app that can unlock a car is a different
  and much more careful piece of software.
- **iOS / iPadOS** — this is a macOS menu bar app.
- **Telemetry** — no analytics, no crash reporting, no phoning home.
