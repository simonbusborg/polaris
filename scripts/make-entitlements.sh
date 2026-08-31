#!/bin/bash
# Write the entitlements the app and its widget are signed with.
#
# Called by the Makefile as: make-entitlements.sh <out-dir> [app-group]
#
# The App Group is what the whole widget rests on: an .appex is always
# sandboxed even though Polaris itself is not, so the shared container is
# the only way the widget sees anything the app knows. On macOS the group
# identifier must carry the Team ID prefix, which is a secret in CI — so a
# build without one is written without the group rather than with a guess.
# It still assembles and signs; the widget reports the missing group.
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

# The extension is sandboxed whether or not we ask for it; saying so keeps
# the entitlements honest about what the binary actually runs under.
{
    cat <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key>
	<true/>
EOF
    group_block
    cat <<'EOF'
</dict>
</plist>
EOF
} > "$OUT/PolarisWidget.entitlements"

if [ -n "$GROUP" ]; then
    echo "entitlements: App Group $GROUP"
else
    echo "entitlements: no TEAM_ID, so no App Group — widget will say so"
fi
