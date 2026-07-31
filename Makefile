APP     = Polaris.app
BINARY  = .build/release/Polaris

.PHONY: build app run clean

## Build the release binary
build:
	swift build -c release

## Assemble a proper .app bundle (needed for launch-at-login) and ad-hoc sign it
app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(BINARY) $(APP)/Contents/MacOS/Polaris
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	cp Resources/Polaris.icns $(APP)/Contents/Resources/Polaris.icns
	codesign --force -s - $(APP)
	@echo "Done → open $(APP)  (or move it to /Applications)"

## Quick run without a bundle (launch-at-login disabled in this mode)
run:
	swift run

clean:
	rm -rf .build $(APP)
