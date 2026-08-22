# Contributing to Polaris

Polaris is a small app with a small maintainer team, so the bar for a change
is less "is this good code" than "will this still be understandable in a
year". These notes are about making that easy, not about ceremony.

## Before you build anything large

Open an issue first. A feature that fits the menu bar is rarely the same
feature you'd build for a full window, and it's cheaper to disagree about the
shape in an issue than in a 900-line pull request.

Small fixes — a wrong string, a crash, a locale bug — need no preamble. Just
send them.

## Building

Requires macOS 13 or later and a Swift 5.9 toolchain.

    make run     # quick launch, no bundle (launch-at-login is disabled here)
    make app     # a real, ad-hoc-signed Polaris.app
    make test    # swift test

`make run` is enough for most work. You need `make app` when you touch
launch-at-login, notifications, or Sparkle, because all three need a genuine
bundle identity — under `swift run` they no-op by design.

## What a good pull request looks like

**One concern per branch.** Branch from current `main`. If your working copy
has picked up unrelated changes — renames, editor settings, a `.gitignore`
you like better — leave them out. A PR that mixes a feature with a rebrand is
a PR nobody can review honestly.

**Don't disable other people's paths.** Polaris talks to the car over a
reverse-engineered gRPC path today. If you add a second backend, it's
additive: it activates when its credentials are present and falls back
silently when they aren't. Nobody's setup should break because a feature they
don't use got merged.

**Explain the why, not the what.** Comments here carry reasoning that isn't
visible in the code — why the keychain item is deleted and re-added, why
nested Sparkle binaries are signed before the outer bundle. Match that. A
comment restating the line below it will be asked about in review.

**Write the strings in all twelve languages, or none.** `Resources/*.lproj`
covers English, Danish, Swedish, Norwegian, Finnish, German, Dutch, French,
Italian, Spanish, Polish and Portuguese. If you can only do some, add the
English key and say so in the PR — a missing key falls back to English, which
is fine. A machine-translated string that reads as machine-translated is not;
flag any you're unsure about and they'll be reviewed.

**Tests must not touch the network.** `swift test` runs in CI on every push
and has no credentials and no car. Decode fixtures, don't fetch them.

**Keep secrets out of defaults.** Credentials and tokens belong in the
Keychain. `UserDefaults` is a plaintext plist in the user's Library — fine for
a window position, wrong for anything about the car's location.

## Sign-off

By opening a pull request you're stating that you wrote the code, that you
have the right to contribute it, and that it's licensed under the same MIT
license as the rest of the project.

If you work somewhere that could plausibly claim ownership of what you wrote
— an employer in the automotive or software industry, a client contract with
an IP assignment clause — say so explicitly in the PR description: that you
wrote it on your own time, on your own equipment, and are free to contribute
it under MIT. This isn't distrust. It's that an MIT project can't quietly
absorb code someone else may own, and one sentence from you settles it
permanently.

## Reporting bugs

Include your macOS version, the Polaris version from the menu, and what the
car was doing at the time — parked, charging, driving. Polestar's API behaves
differently in each, and "it showed the wrong range" is usually a question
about which of those three it was.

Never paste tokens, VINs or your Polestar password into an issue. A VIN
identifies a specific car and its owner.
