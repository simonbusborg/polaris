APP     = Polaris.app
# Universal builds land under .build/apple, not .build/release.
BINARY  = .build/apple/Products/Release/Polaris
DMG     = Polaris.dmg

# Code-signing identity. Default "-" is ad-hoc (local builds); CI passes a
# "Developer ID Application: …" identity for notarized releases.
IDENTITY ?= -

# Team ID, used only to prefix the App Group identifier — on macOS a group
# has to be <TEAM>.group.…, unlike iOS. It's a secret in CI. A build without
# it still assembles and signs; it simply carries no group, and the widget
# says so on its face instead of resolving something plausible and wrong.
TEAM_ID ?=
APP_GROUP = $(if $(TEAM_ID),$(TEAM_ID).group.com.weareheavy.polaris,)

# A Developer ID build that claims an App Group needs that entitlement
# authorised by a provisioning profile embedded in the bundle. Point this at
# a .provisionprofile to embed one. Whether it is genuinely required outside
# the App Store is the question this whole branch exists to answer.
PROFILE ?=

# The widget extension, hand-assembled like the app bundle around it.
WIDGET  = $(APP)/Contents/PlugIns/PolarisWidget.appex
WIDGET_BINARY = .build/apple/Products/Release/PolarisWidget
ENT     = build

# Where SwiftPM unpacked Sparkle's xcframework. The version is in the path,
# so it's found rather than hard-coded.
SPARKLE = $(shell find .build/artifacts -type d -name Sparkle.framework -path '*macos*' | head -1)

# Sparkle ships helpers that are separately-signed code in their own right:
# two XPC services, an Updater.app and the Autoupdate tool. Every one of them
# has to be signed before the framework is, and each has to actually exist —
# an earlier version of this quietly skipped missing paths and the notary
# service rejected the build for unsigned nested code.
SIGN_NESTED = scripts/sign-sparkle.sh $(APP)

.PHONY: build app dmg run test clean release entitlements

## Build the release binary as a universal (Apple silicon + Intel) binary.
## CI runs on an arm64 runner, so a plain `swift build` ships an arm64-only
## app that Intel Macs refuse to launch — the icon gets the prohibitory
## overlay and looks like a Gatekeeper block. Sparkle already ships fat.
build:
	swift build -c release --arch arm64 --arch x86_64

## Assemble a proper .app bundle (needed for launch-at-login) and sign it
app: build entitlements
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(BINARY) $(APP)/Contents/MacOS/Polaris
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	cp Resources/Polaris.icns $(APP)/Contents/Resources/Polaris.icns
	# The .lproj folders are what makes the app follow the system language.
	cp -R Resources/*.lproj $(APP)/Contents/Resources/
	# The widget is a second executable dropped into PlugIns as an .appex.
	# Its Info.plist carries the assembled App Group so the extension can
	# read back the identifier it was signed with rather than hard-coding a
	# Team ID into source.
	mkdir -p $(WIDGET)/Contents/MacOS
	cp $(WIDGET_BINARY) $(WIDGET)/Contents/MacOS/PolarisWidget
	sed -e 's|__APP_GROUP__|$(APP_GROUP)|' \
		Resources/PolarisWidget-Info.plist > $(WIDGET)/Contents/Info.plist
ifneq ($(PROFILE),)
	cp "$(PROFILE)" $(APP)/Contents/embedded.provisionprofile
endif
	# SwiftPM links Sparkle but won't embed it — an executable target has no
	# bundle to embed into. The framework is copied by hand and the binary
	# gets an rpath pointing at it, or the app dies at launch with "Library
	# not loaded".
	mkdir -p $(APP)/Contents/Frameworks
	cp -R "$(SPARKLE)" $(APP)/Contents/Frameworks/
	install_name_tool -add_rpath @executable_path/../Frameworks $(APP)/Contents/MacOS/Polaris
	# Nested code is signed first and the outer bundle last: signing the app
	# seals the frameworks' signatures, so doing it the other way round
	# invalidates them. --deep is Apple-discouraged and does the wrong thing
	# with Sparkle's XPC services.
	# The .appex is nested code too, so it is signed before the app that
	# contains it — and with its own entitlements, because the extension is
	# sandboxed while Polaris is not.
ifeq ($(IDENTITY),-)
	codesign --force --entitlements $(ENT)/PolarisWidget.entitlements -s - $(WIDGET)
	@$(SIGN_NESTED) --force -s -
	codesign --force -s - $(APP)/Contents/Frameworks/Sparkle.framework
	codesign --force --entitlements $(ENT)/Polaris.entitlements -s - $(APP)
else
	codesign --force --options runtime --timestamp --entitlements $(ENT)/PolarisWidget.entitlements -s "$(IDENTITY)" $(WIDGET)
	@$(SIGN_NESTED) --force --options runtime --timestamp -s "$(IDENTITY)"
	codesign --force --options runtime --timestamp -s "$(IDENTITY)" $(APP)/Contents/Frameworks/Sparkle.framework
	codesign --force --options runtime --timestamp --entitlements $(ENT)/Polaris.entitlements -s "$(IDENTITY)" $(APP)
endif
	# Apple rejects the whole submission if one nested binary is unsigned, so
	# prove the bundle is sound here rather than finding out from a notary
	# verdict twenty minutes later.
	codesign --verify --deep --strict --verbose=2 $(APP)
	@echo "Done → open $(APP)  (or move it to /Applications)"

## Package the existing bundle as a drag-to-Applications disk image.
## Deliberately NOT dependent on `app`: that target is phony, and re-running
## it in CI after notarization would re-sign the bundle and void the staple.
dmg:
	@test -d $(APP) || { echo "No $(APP) — run 'make app' first"; exit 1; }
	rm -rf dmg-staging $(DMG)
	mkdir dmg-staging
	cp -R $(APP) dmg-staging/
	ln -s /Applications dmg-staging/Applications
	hdiutil create -volname Polaris -srcfolder dmg-staging -ov -format UDZO $(DMG)
	rm -rf dmg-staging
	@echo "Done → $(DMG)"

## Write the entitlements both binaries are signed with.
entitlements:
	@scripts/make-entitlements.sh $(ENT) "$(APP_GROUP)"

## Quick run without a bundle (launch-at-login disabled in this mode).
## Named explicitly: the package has two executables now, and `swift run`
## with no argument no longer knows which one is meant.
run:
	swift run Polaris

test:
	swift test

clean:
	rm -rf .build $(APP) $(DMG) dmg-staging $(ENT)

## Cut a release: make release VERSION=2.5.0
## Bumps Info.plist, commits, tags v2.5.0, pushes — GitHub Actions then
## builds, packages and publishes the DMG/zip. Same process as Teslaris.
release:
	@test -n "$(VERSION)" || { echo "usage: make release VERSION=x.y.z"; exit 1; }
	@echo "$(VERSION)" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$$' || { echo "VERSION must be x.y.z"; exit 1; }
	@git diff --quiet && git diff --cached --quiet || { echo "working tree not clean"; exit 1; }
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" Resources/Info.plist
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $$(( $$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist) + 1 ))" Resources/Info.plist
	git commit -am "Release v$(VERSION)"
	git tag "v$(VERSION)"
	git push origin HEAD "v$(VERSION)"
	@echo "Done → GitHub Actions is building the release"
