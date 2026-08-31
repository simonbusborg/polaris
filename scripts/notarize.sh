#!/bin/bash
# Submit Polaris.app for notarization and fail on the verdict.
#
# A copy of the release workflow's notarization step, so the spike proves
# something about the path releases actually take. If the widget ships, the
# release workflow should call this instead of keeping a second copy —
# until then release.yml is deliberately left untouched, because a spike
# branch has no business changing how releases are cut.
#
# Expects APPLE_ID, TEAM_ID and APP_PASSWORD in the environment.
set -euo pipefail

ditto -c -k --keepParent Polaris.app notarize.zip
# --wait exits 0 even when the verdict is Invalid, and the verdict alone
# doesn't say what Apple objected to. Fetch the log and fail on it.
ID=$(xcrun notarytool submit notarize.zip \
       --apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_PASSWORD" \
       --output-format json | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
xcrun notarytool wait "$ID" \
  --apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_PASSWORD" || true
xcrun notarytool log "$ID" \
  --apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_PASSWORD" notary.json || true
cat notary.json
python3 -c 'import json,sys; d=json.load(open("notary.json")); sys.exit(0 if d.get("status")=="Accepted" else 1)'
