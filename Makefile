APP_NAME := Hansel
BUILD_DIR := build
APP_BUNDLE := $(BUILD_DIR)/$(APP_NAME).app
CONTENTS := $(APP_BUNDLE)/Contents
BINARY_SRC := .build/release/$(APP_NAME)
BINARY_DST := $(CONTENTS)/MacOS/$(APP_NAME)
PLIST_SRC := Resources/Info.plist
PLIST_DST := $(CONTENTS)/Info.plist
ICON_SRC := Resources/AppIcon.icns
ICON_DST := $(CONTENTS)/Resources/AppIcon.icns
ENTITLEMENTS := Resources/TimeTracker.entitlements

INSTALL_DIR := /Applications
INSTALLED_APP := $(INSTALL_DIR)/$(APP_NAME).app
OLD_INSTALLED_APP := $(INSTALL_DIR)/TimeTracker.app

.PHONY: all app build run clean test install uninstall icon

all: app

build:
	swift build -c release

icon:
	swift scripts/make_icon.swift

app: build
	mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	cp $(BINARY_SRC) $(BINARY_DST)
	cp $(PLIST_SRC) $(PLIST_DST)
	@if [ -f $(ICON_SRC) ]; then cp $(ICON_SRC) $(ICON_DST); else echo "⚠  $(ICON_SRC) missing — run 'make icon'"; fi
	codesign --force --deep --sign - --entitlements $(ENTITLEMENTS) --options runtime $(APP_BUNDLE)
	@echo "Built $(APP_BUNDLE)"

run: app
	open $(APP_BUNDLE)

test:
	swift test

# Copy the freshly-built .app into /Applications and launch it from there.
# Kills any running instance first so the bundle can be replaced.
install: app
	-killall $(APP_NAME) 2>/dev/null
	-rm -rf $(OLD_INSTALLED_APP)
	rm -rf $(INSTALLED_APP)
	cp -R $(APP_BUNDLE) $(INSTALLED_APP)
	/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f $(INSTALLED_APP)
	@echo "Installed $(INSTALLED_APP)"
	@echo ""
	@echo "Next steps:"
	@echo "  1. Launch from Spotlight (Cmd+Space \"Hansel\") or Launchpad"
	@echo "  2. Re-grant Calendar / Accessibility / Automation permissions"
	@echo "     (the new install has a different code-sign hash than the dev build)"
	@echo "  3. Settings \xe2\x86\x92 General \xe2\x86\x92 toggle \"Launch at login\" on"

uninstall:
	-killall $(APP_NAME) 2>/dev/null
	rm -rf $(INSTALLED_APP) $(OLD_INSTALLED_APP)
	@echo "Removed $(INSTALLED_APP)"

clean:
	swift package clean
	rm -rf $(BUILD_DIR) .build
