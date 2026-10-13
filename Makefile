APP_NAME   := VolumeMixer
BUNDLE_ID  := se.qte.volumemixer
CONFIG     := release
BIN        := .build/$(CONFIG)/$(APP_NAME)
APP        := build/$(APP_NAME).app
SIGN_ID    ?= VolumeMixer Dev

# Distribution to other Macs. Requires an Apple Developer Program membership:
# DEVELOPER_ID is the "Developer ID Application: ..." identity, NOTARY_PROFILE the name
# given to `xcrun notarytool store-credentials` (see `make dist-setup`).
DEVELOPER_ID   ?=
NOTARY_PROFILE ?= volumemixer
ZIP            := build/$(APP_NAME).zip

.PHONY: all build bundle sign run debug stop test clean cert-help dist dist-setup

all: sign

build:
	swift build -c $(CONFIG)

bundle: build
	@rm -rf $(APP)
	@mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	@cp $(BIN) $(APP)/Contents/MacOS/$(APP_NAME)
	@cp Resources/Info.plist $(APP)/Contents/Info.plist
	@printf 'APPL????' > $(APP)/Contents/PkgInfo
	@echo "bundled $(APP)"

sign: bundle
	@if security find-identity -v -p codesigning | grep -q "$(SIGN_ID)"; then \
		codesign --force --options runtime --sign "$(SIGN_ID)" $(APP) && \
		echo "signed with '$(SIGN_ID)'"; \
	else \
		echo "warning: no codesigning identity '$(SIGN_ID)' found - signing ad-hoc."; \
		echo "         macOS will re-ask for audio permission after every build."; \
		echo "         run 'make cert-help' for how to create a stable identity."; \
		codesign --force --sign - $(APP); \
	fi

run: stop sign
	@open $(APP)
	@echo "running - look for the slider icon in the menu bar"

# Same app, but with the per-IO-proc diagnostics in the unified log:
#   /usr/bin/log stream --predicate 'subsystem == "se.qte.volumemixer"'
debug: stop sign
	@VOLUMEMIXER_DEBUG=1 open $(APP) --env VOLUMEMIXER_DEBUG=1
	@echo "running with diagnostics - /usr/bin/log stream --predicate 'subsystem == \"se.qte.volumemixer\"'"

stop:
	@pkill -x $(APP_NAME) 2>/dev/null || true

test:
	@swift run -c $(CONFIG) SelfTest

clean:
	@rm -rf .build build

cert-help:
	@echo "Create a stable self-signed signing identity:"
	@echo "  1. Open Keychain Access"
	@echo "  2. Menu: Keychain Access > Certificate Assistant > Create a Certificate..."
	@echo "  3. Name: $(SIGN_ID)"
	@echo "     Identity Type: Self Signed Root"
	@echo "     Certificate Type: Code Signing"
	@echo "  4. Verify with: security find-identity -v -p codesigning"

dist-setup:
	@echo "One-time setup for notarised distribution:"
	@echo "  1. Join the Apple Developer Program (99 USD/year)"
	@echo "  2. Create a 'Developer ID Application' certificate and install it in your keychain"
	@echo "  3. Create an app-specific password at https://appleid.apple.com"
	@echo "  4. Store the credentials once:"
	@echo "       xcrun notarytool store-credentials \"$(NOTARY_PROFILE)\" \\"
	@echo "         --apple-id <your-apple-id> --team-id <TEAMID> --password <app-specific-password>"
	@echo "  5. Build and ship:  make dist DEVELOPER_ID=\"Developer ID Application: Name (TEAMID)\""

dist: bundle
	@test -n "$(DEVELOPER_ID)" || { echo "error: set DEVELOPER_ID - see 'make dist-setup'"; exit 1; }
	codesign --force --options runtime --timestamp --sign "$(DEVELOPER_ID)" $(APP)
	codesign --verify --strict --verbose=2 $(APP)
	@rm -f $(ZIP)
	ditto -c -k --keepParent $(APP) $(ZIP)
	xcrun notarytool submit $(ZIP) --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple $(APP)
	@rm -f $(ZIP)
	ditto -c -k --keepParent $(APP) $(ZIP)
	@echo
	@echo "$(ZIP) is signed, notarised and stapled."
	@echo "Anyone can unzip it and double-click the app - no Gatekeeper warning."
