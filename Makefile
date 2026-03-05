APP_NAME = Refreshing
BUNDLE = $(APP_NAME).app
SRC_DIR = Refreshing/Refreshing
SOURCES = $(SRC_DIR)/DisplayManager.swift \
          $(SRC_DIR)/SleepWakeManager.swift \
          $(SRC_DIR)/AppState.swift \
          $(SRC_DIR)/MenuBarView.swift \
          $(SRC_DIR)/RefreshingApp.swift

TARGET = arm64-apple-macos15.0
SDK = $(shell xcrun --show-sdk-path)
FRAMEWORKS = -framework Cocoa -framework IOKit -framework ServiceManagement
BUILD_DIR = /tmp/refreshing-build

.PHONY: all clean install

all:
	@rm -rf $(BUILD_DIR)/$(BUNDLE)
	@mkdir -p $(BUILD_DIR)/$(BUNDLE)/Contents/MacOS $(BUILD_DIR)/$(BUNDLE)/Contents/Resources
	@COPYFILE_DISABLE=1 cp $(SRC_DIR)/Info.plist $(BUILD_DIR)/$(BUNDLE)/Contents/Info.plist
	@COPYFILE_DISABLE=1 cp $(SRC_DIR)/AppIcon.icns $(BUILD_DIR)/$(BUNDLE)/Contents/Resources/AppIcon.icns
	xcrun swiftc -target $(TARGET) -sdk $(SDK) $(FRAMEWORKS) -o $(BUILD_DIR)/$(BUNDLE)/Contents/MacOS/$(APP_NAME) $(SOURCES)
	@codesign -s - --force --deep $(BUILD_DIR)/$(BUNDLE)
	@rm -rf $(BUNDLE)
	@cp -R $(BUILD_DIR)/$(BUNDLE) $(BUNDLE)

clean:
	rm -rf $(BUNDLE) $(BUILD_DIR)/$(BUNDLE)

install: all
	@rm -rf /Applications/$(BUNDLE)
	@cp -R $(BUILD_DIR)/$(BUNDLE) /Applications/$(BUNDLE)
