#!/bin/bash
# Submit Polaris.app for notarization, fail on the verdict, then staple.
#
# Called by the release and signed-build workflows. It lives in a script
# rather than inline in the YAML so the same submission can be run by hand
# when a release needs re-notarizing, and so there is only one copy of it to
# get wrong.
#
# Expects APPLE_ID, TEAM_ID and APP_PASSWORD in the environment.
set -euo pipefail

# Apple's notary and ticket services drop connections often enough to kill a
# release halfway, after the appcast and the tag are already committed to.
# Every network step is retried; the verdict itself never is, because an
# Invalid submission fails the same way however often it is sent.
retry() {
  local attempt
  for attempt in 1 2 3 4; do
    "$@" && return 0
    [ "$attempt" -lt 4 ] || break
    echo "::warning::'$*' failed (attempt $attempt), retrying in $((attempt * 20))s"
    sleep $((attempt * 20))
  done
  return 1
}

AUTH=(--apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_PASSWORD")

ditto -c -k --keepParent Polaris.app notarize.zip
# The redirect sits inside the function so a failed attempt's output can't
# end up in front of the successful one's JSON.
submit() { xcrun notarytool submit notarize.zip "${AUTH[@]}" --output-format json > submit.json; }
retry submit
ID=$(python3 -c 'import json; print(json.load(open("submit.json"))["id"])')
# --wait exits 0 even when the verdict is Invalid, and the verdict alone
# doesn't say what Apple objected to. Fetch the log and fail on it.
retry xcrun notarytool wait "$ID" "${AUTH[@]}" || true
retry xcrun notarytool log "$ID" "${AUTH[@]}" notary.json
cat notary.json
python3 -c 'import json,sys; d=json.load(open("notary.json")); sys.exit(0 if d.get("status")=="Accepted" else 1)'

# The ticket can take a moment to propagate to the CDN stapler fetches from,
# which reads as the same transient failure.
retry xcrun stapler staple Polaris.app
