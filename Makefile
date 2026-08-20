APP     = Polaris.app
BINARY  = .build/release/Polaris
DMG     = Polaris.dmg

# Code-signing identity. Default "-" is ad-hoc (local builds); CI passes a
# "Developer ID Application: …" identity for notarized releases.
IDENTITY ?= -

.PHONY: build app dmg run test clean release

## Build the release binary
build:
	swift build -c release

## Assemble a proper .app bundle (needed for launch-at-login) and sign it
app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(BINARY) $(APP)/Contents/MacOS/Polaris
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	cp Resources/Polaris.icns $(APP)/Contents/Resources/Polaris.icns
	# The .lproj folders are what makes the app follow the system language.
	cp -R Resources/*.lproj $(APP)/Contents/Resources/
ifeq ($(IDENTITY),-)
	codesign --force -s - $(APP)
else
	codesign --force --options runtime --timestamp -s "$(IDENTITY)" $(APP)
endif
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

## Quick run without a bundle (launch-at-login disabled in this mode)
run:
	swift run

test:
	swift test

clean:
	rm -rf .build $(APP) $(DMG) dmg-staging

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
