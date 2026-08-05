SHELL := /bin/bash

PROJECT := MacClippy.xcodeproj
SCHEME := MacClippy
PACKAGE_DIR := MacClippyKit
DESTINATION := platform=macOS,arch=arm64
DERIVED_DATA ?= $(CURDIR)/.build/DerivedData
DEBUG_APP := $(DERIVED_DATA)/Build/Products/Debug/MacClippy.app
ARCHIVE_PATH ?= $(CURDIR)/build/archives/MacClippy.xcarchive
RELEASE_DERIVED_DATA ?= $(CURDIR)/build/derived-data
RELEASE_APP := $(ARCHIVE_PATH)/Products/Applications/MacClippy.app
RELEASE_UNSIGNED_APP := $(RELEASE_DERIVED_DATA)/Build/Products/Release/MacClippy.app

XCODEBUILD_FLAGS := \
	-project "$(PROJECT)" \
	-scheme "$(SCHEME)" \
	-configuration Debug \
	-destination "$(DESTINATION)" \
	-derivedDataPath "$(DERIVED_DATA)" \
	-skipPackagePluginValidation \
	CODE_SIGNING_ALLOWED=NO

.PHONY: generate build test ci dmg release build-release-unsigned verify-build-metadata archive-signed verify-signed notarize clean

generate:
	xcodegen generate

build: generate
	xcodebuild $(XCODEBUILD_FLAGS) build

test: generate
	swift test --package-path "$(PACKAGE_DIR)"
	xcodebuild $(XCODEBUILD_FLAGS) test

ci: generate
	swift test --package-path "$(PACKAGE_DIR)"
	xcodebuild $(XCODEBUILD_FLAGS) build
	xcodebuild $(XCODEBUILD_FLAGS) test

dmg:
	./scripts/package-dmg.sh

release: dmg

build-release-unsigned: generate
	xcodebuild -project "$(PROJECT)" -scheme "$(SCHEME)" \
		-configuration Release -destination "$(DESTINATION)" \
		-derivedDataPath "$(RELEASE_DERIVED_DATA)" \
		-skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO \
		ENABLE_HARDENED_RUNTIME=YES build
	./scripts/verify-build-metadata.sh "$(RELEASE_UNSIGNED_APP)"

verify-build-metadata:
	./scripts/verify-build-metadata.sh "$(DEBUG_APP)"

archive-signed: generate
	DEVELOPER_IDENTITY="$${DEVELOPER_IDENTITY:-}" \
	DEVELOPMENT_TEAM="$${DEVELOPMENT_TEAM:-}" \
	ARCHIVE_PATH="$(ARCHIVE_PATH)" \
		./scripts/archive-signed.sh

verify-signed:
	./scripts/verify-signed.sh "$(RELEASE_APP)"

notarize:
	./scripts/notarize.sh

run: build
	@test -d "$(DEBUG_APP)" || { echo "error: expected app at $(DEBUG_APP)" >&2; exit 1; }
	open -n "$(DEBUG_APP)"

clean:
	rm -rf "$(DERIVED_DATA)" "$(PROJECT)" "$(PACKAGE_DIR)/.build"
