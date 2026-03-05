APP_NAME = Refreshing
BUNDLE = $(APP_NAME).app
BINARY = $(BUNDLE)/Contents/MacOS/$(APP_NAME)
SRC_DIR = Refreshing/Refreshing
SOURCES = $(SRC_DIR)/DisplayManager.swift \
          $(SRC_DIR)/SleepWakeManager.swift \
          $(SRC_DIR)/AppState.swift \
          $(SRC_DIR)/MenuBarView.swift \
          $(SRC_DIR)/RefreshingApp.swift

TARGET = arm64-apple-macos15.0
SDK = $(shell xcrun --show-sdk-path)
FRAMEWORKS = -framework Cocoa -framework IOKit -framework ServiceManagement

.PHONY: all clean install sign

all: $(BINARY) sign

$(BINARY): $(SOURCES)
	@mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	@COPYFILE_DISABLE=1 cp $(SRC_DIR)/Info.plist $(BUNDLE)/Contents/Info.plist
	@COPYFILE_DISABLE=1 cp $(SRC_DIR)/AppIcon.icns $(BUNDLE)/Contents/Resources/AppIcon.icns
	xcrun swiftc -target $(TARGET) -sdk $(SDK) $(FRAMEWORKS) -o $(BINARY) $(SOURCES)

sign: $(BINARY)
	@dot_clean $(BUNDLE) 2>/dev/null || true
	@find $(BUNDLE) -name '._*' -delete 2>/dev/null || true
	@find $(BUNDLE) -type f -exec xattr -c {} \; 2>/dev/null || true
	@find $(BUNDLE) -type d -exec xattr -c {} \; 2>/dev/null || true
	@COPYFILE_DISABLE=1 codesign -s - --force --deep $(BUNDLE)

clean:
	rm -rf $(BUNDLE)

install: $(BINARY)
	@rm -rf /Applications/$(BUNDLE)
	@COPYFILE_DISABLE=1 tar cf - $(BUNDLE) | tar xf - -C /Applications/
	@dot_clean /Applications/$(BUNDLE) 2>/dev/null || true
	@find /Applications/$(BUNDLE) -name '._*' -delete 2>/dev/null || true
	@find /Applications/$(BUNDLE) -type f -exec xattr -c {} \; 2>/dev/null || true
	@find /Applications/$(BUNDLE) -type d -exec xattr -c {} \; 2>/dev/null || true
	@codesign -s - --force --deep /Applications/$(BUNDLE)
