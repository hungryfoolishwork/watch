NAME := Project
XCB := xcodebuild -project app/$(NAME).xcodeproj
BUILD_DIR := .build/xcode
CONFIG ?= Debug

# Read from the xcconfig so the bundle ID is defined in one place.
BUNDLE_ID := $(shell sed -n 's/^APP_BUNDLE_IDENTIFIER = //p' app/Config/Shared.xcconfig)

# UDID of the first paired physical iPhone, looked up on first use and then cached, so
# devicectl runs at most once and only for targets that need it. Override with DEVICE=<udid>.
DEVICE ?= $(eval DEVICE := $(shell xcrun devicectl list devices --quiet --json-output /dev/stdout 2>/dev/null | jq -r '$(UDID_FILTER)'))$(DEVICE)

# jq filter for the lookup above. Kept in a define because bare parentheses inside
# $(shell ...) break Makefile syntax highlighting in some editors.
define UDID_FILTER
[.result.devices[] | select(.hardwareProperties.reality == "physical" and .hardwareProperties.deviceType == "iPhone")][0].hardwareProperties.udid // empty
endef

# Build and test without launching. build-ios targets the simulator, so it needs no device.
.PHONY: build build-ios test

build:
	$(XCB) -scheme $(NAME) -destination 'platform=macOS' build

build-ios:
	$(XCB) -scheme $(NAME)-iOS -destination 'generic/platform=iOS Simulator' build

test:
	$(XCB) -scheme $(NAME) -destination 'platform=macOS' test

# Build and launch. Debug by default; pass CONFIG=Release or use the -release targets.
# run-ios installs to a connected iPhone (see DEVICE above).
.PHONY: run run-release run-ios run-ios-release

run:
	$(XCB) -scheme $(NAME) -configuration $(CONFIG) \
		-destination 'platform=macOS' -derivedDataPath $(BUILD_DIR) build
	open $(BUILD_DIR)/Build/Products/$(CONFIG)/$(NAME).app

run-release:
	$(MAKE) run CONFIG=Release

run-ios:
	@test -n "$(DEVICE)" || { echo "No paired iPhone found; pass DEVICE=<udid>." >&2; exit 1; }
	$(XCB) -scheme $(NAME)-iOS -configuration $(CONFIG) -destination 'id=$(DEVICE)' \
		-derivedDataPath $(BUILD_DIR) -allowProvisioningUpdates build
	xcrun devicectl device install app --device $(DEVICE) $(BUILD_DIR)/Build/Products/$(CONFIG)-iphoneos/$(NAME).app
	xcrun devicectl device process launch --device $(DEVICE) $(BUNDLE_ID)

run-ios-release:
	$(MAKE) run-ios CONFIG=Release

# Release builds for App Store Connect. Archive, then upload the archive straight to App Store
# Connect with the account signed in to Xcode. The build number is APP_VERSION in
# app/Config/Shared.xcconfig; bump it before archiving a build to upload.
ARCHIVES := .build/archives
EXPORT_OPTIONS := app/Config/ExportOptions.plist

.PHONY: archive archive-ios upload upload-ios release release-ios

# Archive, then upload, stopping if the archive fails. Steps rather than prerequisites, so
# `make -j` can't run them at once.
release:
	$(MAKE) archive
	$(MAKE) upload

release-ios:
	$(MAKE) archive-ios
	$(MAKE) upload-ios

archive:
	$(XCB) -scheme $(NAME) -configuration Release -destination 'generic/platform=macOS' \
		-archivePath $(ARCHIVES)/$(NAME).xcarchive -allowProvisioningUpdates archive

archive-ios:
	$(XCB) -scheme $(NAME)-iOS -configuration Release -destination 'generic/platform=iOS' \
		-archivePath $(ARCHIVES)/$(NAME)-iOS.xcarchive -allowProvisioningUpdates archive

upload:
	xcodebuild -exportArchive -archivePath $(ARCHIVES)/$(NAME).xcarchive -exportOptionsPlist $(EXPORT_OPTIONS) \
		-exportPath $(ARCHIVES)/upload/macOS -allowProvisioningUpdates

upload-ios:
	xcodebuild -exportArchive -archivePath $(ARCHIVES)/$(NAME)-iOS.xcarchive -exportOptionsPlist $(EXPORT_OPTIONS) \
		-exportPath $(ARCHIVES)/upload/iOS -allowProvisioningUpdates

# Website (site/): Go, no dependencies. Run locally on http://127.0.0.1:8418.
.PHONY: site-run site-test site-linux

site-run:
	cd site && WILD_SITE_DATA=data go run .

site-test:
	cd site && go vet ./... && go test ./...

site-linux:
	cd site && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags='-s -w' -o ../.build/wild-site .
