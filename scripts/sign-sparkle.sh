#!/bin/bash
# Sign the code nested inside Sparkle.framework, innermost first.
#
# Called by the Makefile as: sign-sparkle.sh <app> <codesign args…>
# Fails when it finds nothing to sign, because that means Sparkle's layout
# moved and the previous silent skip is what produced an Invalid notary
# verdict.
set -euo pipefail

APP="$1"; shift
FW="$APP/Contents/Frameworks/Sparkle.framework"
test -d "$FW" || { echo "no Sparkle.framework in $APP"; exit 1; }

signed=0
while IFS= read -r target; do
    echo "signing $target"
    codesign "$@" "$target"
    signed=$((signed + 1))
# Deepest first: signing a container seals what's inside it, so anything
# nested has to be signed before its parent.
done < <(find "$FW" -maxdepth 4 \( -name '*.xpc' -o -name '*.app' -o -name 'Autoupdate' \) \
         | awk '{print gsub(/\//,"/"), $0}' | sort -rn | cut -d' ' -f2-)

test "$signed" -gt 0 || { echo "found nothing to sign inside Sparkle.framework"; exit 1; }
echo "signed $signed nested items"
