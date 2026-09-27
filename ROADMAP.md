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

Don't put `Closes #…` in a commit message. GitHub acts on it the moment the
commit reaches `main`, which closes the issue a release too early and skips
the comment that was the whole point. Reference the issue by number instead.

Everything public is written in English — issues, comments, releases, this
file. The people asking are from all over Polestar's markets, and a reply in
Danish is a reply only Simon can read.

The comment is the point. A silently closed issue tells the person who asked
nothing, and this roadmap's "Shipped" list is only trustworthy if every entry
has a version next to it. An issue that got *partly* solved stays open with a
comment describing where it now stands.

## Next

- **Data Portal as a registered third party** — today the owner creates a
  credential and pastes three values. Polestar's portal lets owners share
  access with registered apps instead, which would make setup a consent
  click and keep the secret out of everyone's hands. Registration has been
  requested; this waits on Polestar's answer.
- **[Something left open](https://github.com/simonbusborg/polaris/issues/14)** — the Doors row already says which door, the
  tailgate or a window is ajar. This makes it a reminder: the car has been
  parked a few minutes with something open, or unlocked, and nobody is in
  it. Opt-in under Notifications like the parked-at-home reminder, once per
  stay, and quiet while the car is in use.
- **[Tyres and the 12V battery](https://github.com/simonbusborg/polaris/issues/15)** — the Data Portal's health domain reports
  tyre pressure per wheel, the 12V battery and the lights, and Polaris reads
  only the service interval and fluids from it. A tyre warning becomes a row
  and a notification; a failing 12V battery is the one fault that strands an
  EV, so it gets the same.
- **[Credential expiry](https://github.com/simonbusborg/polaris/issues/16)** — a Data Portal
  credential lives 90 days and Polaris doesn't know when it dies. An expiry
  date in Settings, a reminder a week before and on the day with a button to
  the portal, and a failure row that says "expired" instead of "rejected".
- **A map widget** — the menu has the map; a widget size built around it is
  a different piece of work and waits until the rows above have settled.

## Being looked at

These depend on what the API actually exposes, which is not something that
can be promised before someone has tried it.

- **[Charging history](https://github.com/simonbusborg/polaris/issues/5)** — a log of recent sessions rather than only what's
  happening right now. The Data Portal keeps no history either, so this is
  ours to record.

## Shipped

- **Claude can say where the car is** (v3.1.0) — a switch under Settings →
  Claude, off by default, lets the helper answer "where is my car?" with the
  same words the widget shows: Home, or a street and town. Never a
  coordinate, never inside the status answer, and the privacy line in the
  pane now says exactly that.
- **Polestar Data Portal** (v3.0.0) — Polaris can read your car through
  Polestar's official Data Portal API. Create a credential at
  data-portal.polestar.com, paste it under Settings → Data Portal, and
  battery, charging, odometer and health come from the supported API; your
  login stays for the car's name and picture, and takes over again if the
  credential stops working.
- **In use, from the car** (v3.0.0) — with the Data Portal the car says
  outright whether it's being driven, instead of Polaris inferring it from
  the odometer. Closes the long-standing "in use" issue.
- **Climate, charge limit, doors and where it's parked** (v3.0.0) — new
  rows in the menu, each appearing as its Data Portal scope allows: the
  parking climate with its target and countdown, the charge limit, the
  locks and anything left open, and the car's position as a street and a
  small map that opens in Maps. Readings older than half an hour say so.
  The large widget carries the same rows; the medium one adds a line only
  when something needs attention. Claude gets the same facts, minus the
  location.
- **Parked at home, not charging** (v3.0.0) — an optional reminder when the
  car has sat at home for ten minutes with the charger disconnected. Home
  is a point you save from the car's own position, under Notifications.
- **One honest change to the privacy line** (v3.0.0) — to show a street
  name and a map, the car's position goes to Apple's geocoder and MapKit.
  That happens only with the Data Portal's location scope on, and it's the
  one thing Polaris sends anywhere but Polestar.
- **Ask Claude about your car** (v2.11.0) — a Claude tab in Settings adds
  Polaris to Claude Desktop in one click, and Claude can then answer "what's my
  battery?" or "can I get to Aarhus and back?" from what the app last fetched.
  It is a small helper inside the app that reads the widget's snapshot: no
  password, VIN or location ever reaches Claude, it makes no request of its own
  to Polestar, and it can only read.

- **Choose how often the car is polled** (v2.10.0) — a "Refresh while parked"
  setting in the menu bar pane: every 1, 2, 5, 10 or 15 minutes, applied the
  moment it's changed. Charging and driving still refresh every minute — those
  are the moments the numbers actually move.

- **The menu speaks VoiceOver** (v2.10.0) — the data rows, the car image and
  the widget now carry proper accessibility labels, so "Battery, 78%" is read
  aloud instead of silence. Decorative pieces like the battery bar stay quiet
  rather than repeating what the text next to them already says.

- **Readable release notes in the update window** (v2.10.0) — Sparkle's update
  panel now shows what a release means for you, written from this roadmap,
  instead of raw commit subjects.

- **No more half-translated greeting** (v2.10.0) — Chinese and Korean systems
  got a localized "hello" atop an otherwise English menu; the greeting now only
  speaks languages the rest of the app speaks too.

- **First run asks for your account** (v2.9.0) — signing in happens while you
  watch, with the failure shown under the field that caused it, and the car is
  picked from what the account reports instead of typed in as a VIN. The last
  screen says where the app went, which is the question a menu-bar-only app
  leaves people with.

- **Sign out** (v2.9.0) — there was no way out short of deleting the app and its
  Keychain items by hand: removing an account lived behind a button hidden until
  a second car existed. It is always there now, and signing out of the last
  account returns the app to its fresh-install state.

- **Settings as panes** (v2.9.0) — a toolbar of five panes rather than one column
  taller than the window, every control applying the moment it is changed, and a
  status line saying whether the app is actually talking to the car. The version
  moved to an About pane.

- **A disk image that looks like the download page** (v2.9.0) — the installer
  window now arrives sized, with its background and both icons placed, instead of
  as a Finder file listing.

- **Desktop widget** (v2.8.0) — small, medium and large. It reads what the app
  last fetched rather than polling on its own, so adding one doesn't add a
  request to your car, and clicking it drops the menu. The large size carries
  the studio render of your exact car.

- **Appcast published by CI** (v2.7.0) — the update feed is signed and
  committed by the release workflow. The v2.6.0 entry was the last one made
  by hand.

- **Homebrew cask** (v2.6.0) — `brew install --cask simonbusborg/polaris/polaris`,
  kept current by the release workflow.
- **In-app updates** (v2.6.0) — "Check for Updates…" in the menu, plus
  automatic checking and installing, via Sparkle.
- **More than one car, across accounts** (v2.6.0) — "Add Car…" in Settings;
  every car from every login shows up in the same switcher.

- **Signed and notarized builds** (v2.5.1) — releases are signed with a
  Developer ID and notarized by Apple. The first-launch security warning is
  gone.

- **Multiple cars** (v2.2.0) — a switcher appears in the menu when the
  account has more than one car.
- **System language, 12 languages** (v2.5.0, five more in v2.6.0) — English, Danish,
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
- **iOS, iPadOS and watchOS** — the official Polestar API this was waiting
  for now exists, so the App Store objection is gone. What remains is that iOS
  won't let an app poll the car in the background, so charging notifications
  would need a server of ours in the middle. Reopened, not planned yet; this
  stays a macOS menu bar app until that has an answer.
- **ChatGPT and other web-based AI clients** — they can only reach a server on
  the internet, and Polaris keeps your car's data on your Mac. Serving it from a
  public address would trade that away, and add an authentication problem to a
  project that has none. If ChatGPT learns to launch a local helper the way
  Claude Desktop does, it should work without changes.
- **Telemetry** — no analytics, no crash reporting, no phoning home.
