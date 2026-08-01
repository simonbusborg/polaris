APP     = Polaris.app
BINARY  = .build/release/Polaris
DMG     = Polaris.dmg

# Code-signing identity. Default "-" is ad-hoc (local builds); CI passes a
# "Developer ID Application: …" identity for notarized releases.
IDENTITY ?= -

.PHONY: build app dmg run test clean

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
