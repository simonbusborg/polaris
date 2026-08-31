#!/bin/bash
# Write the entitlements the app and its widget are signed with.
#
# Called by the Makefile as: make-entitlements.sh <out-dir> [app-group]
#
# The App Group is what the whole widget rests on: a sandboxed .appex can
# only see what the app leaves in the shared container. On macOS the group
# identifier must carry the Team ID prefix, which is a secret in CI.
#
# A build with no Team ID can't have one: macOS validates an app group
# against the team in the signature, and an ad-hoc build has no team, so the
# container URL resolves and every read is denied — which looks exactly like
# a bug in the app. Such a build gets a sandbox exception for a plain folder
# instead, and SharedStore points both processes there.
#
# The sandbox itself stays on either way. WidgetKit will not register an
# unsandboxed extension at all: the widget simply stops appearing in the
# gallery, with nothing anywhere to say why.
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

# Where a local build's widget is allowed to read, since it has no group.
# An absolute path baked into the entitlements is only defensible because
# these are the entitlements of a build that never leaves this machine.
local_exception() {
    test -z "$GROUP" || return 0
    cat <<EOF
	<key>com.apple.security.temporary-exception.files.absolute-path.read-only</key>
	<array>
		<string>$HOME/Library/Application Support/Polaris/</string>
	</array>
EOF
}

{
    cat <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key>
	<true/>
EOF
    local_exception
    group_block
    cat <<'EOF'
</dict>
</plist>
EOF
} > "$OUT/PolarisWidget.entitlements"

if [ -n "$GROUP" ]; then
    echo "entitlements: App Group $GROUP"
else
    echo "entitlements: no TEAM_ID — local build reading $HOME/Library/Application Support/Polaris"
fi
