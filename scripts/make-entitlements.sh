#!/bin/bash
# Write the entitlements the app and its widget are signed with.
#
# Called by the Makefile as: make-entitlements.sh <out-dir> [app-group]
#
# The App Group is what the whole widget rests on: a sandboxed .appex can
# only see what the app leaves in the shared container. On macOS the group
# identifier must carry the Team ID prefix, which is a secret in CI.
#
# A build with no Team ID gets neither the group nor the sandbox, and that
# pairing is the point. macOS validates an app group against the team in the
# signature, so an ad-hoc build can never be granted one: the container URL
# resolves and every read is then denied, which looks exactly like a bug in
# the app. Dropping the sandbox with it lets the widget fall back to a plain
# directory both processes can reach, so a local `make app` produces a widget
# that actually works. See SharedStore.containerURL for the other half.
set -euo pipefail

OUT="$1"
GROUP="${2:-}"
mkdir -p "$OUT"

group_block() {
    test -n "$GROUP" || return 0
    cat <<EOF
	<key>com.apple.security.application-groups</key>
	<array>
		<string>$GROUP</string>
	</array>
EOF
}

{
    cat <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
EOF
    group_block
    cat <<'EOF'
</dict>
</plist>
EOF
} > "$OUT/Polaris.entitlements"

sandbox_block() {
    test -n "$GROUP" || return 0
    cat <<EOF
	<key>com.apple.security.app-sandbox</key>
	<true/>
EOF
}

{
    cat <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
EOF
    sandbox_block
    group_block
    cat <<'EOF'
</dict>
</plist>
EOF
} > "$OUT/PolarisWidget.entitlements"

if [ -n "$GROUP" ]; then
    echo "entitlements: App Group $GROUP"
else
    echo "entitlements: no TEAM_ID — local build, widget unsandboxed on a shared folder"
fi
