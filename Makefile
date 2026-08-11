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

.PHONY: generate build test test-scale test-stress test-tsan test-app-tsan lint ci ci-fast ci-full dmg release build-release-unsigned verify-build-metadata archive-signed verify-signed notarize clean

generate:
	xcodegen generate

build: generate
	xcodebuild $(XCODEBUILD_FLAGS) build

test: generate
	swift test --package-path "$(PACKAGE_DIR)"
	xcodebuild $(XCODEBUILD_FLAGS) test

test-scale: generate
	MACCLIPPY_RUN_SCALE_TESTS=1 swift test --package-path "$(PACKAGE_DIR)" --filter MacClippyScaleTests

test-stress: generate
	MACCLIPPY_RUN_STRESS_TESTS=1 swift test --package-path "$(PACKAGE_DIR)" --filter MacClippyLifecycleStressTests

test-tsan: generate
	swift test --package-path "$(PACKAGE_DIR)" --sanitize=thread

test-app-tsan: generate
	xcodebuild test -project "$(PROJECT)" -scheme "$(SCHEME)" \
		-configuration Debug -destination "$(DESTINATION)" \
		-derivedDataPath "$(DERIVED_DATA)/AppTSan" \
		-resultBundlePath "$(CURDIR)/build/app-tsan.xcresult" \
		-parallel-testing-enabled NO -maximum-parallel-testing-workers 1 \
		-enableThreadSanitizer YES -skipPackagePluginValidation \
		CODE_SIGNING_ALLOWED=NO

lint:
	./scripts/lint.sh

ci-fast: generate lint
	swift test --package-path "$(PACKAGE_DIR)"
	xcodebuild $(XCODEBUILD_FLAGS) build
	xcodebuild $(XCODEBUILD_FLAGS) test

ci-full: ci-fast test-scale test-stress test-tsan test-app-tsan build-release-unsigned

ci: ci-full

dmg:
	@set -e; \
	identity="$${DEVELOPER_IDENTITY:-$$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/^[[:space:]]*[0-9]+\)/ { if ($$2 ~ /^Developer ID Application:/) { print $$2; found=1; exit } if (!first) first=$$2 } END { if (!found && first) print first }')}"; \
	if [ -n "$$identity" ]; then \
		team="$${DEVELOPMENT_TEAM:-$$(security find-certificate -c "$$identity" -p 2>/dev/null | openssl x509 -noout -subject 2>/dev/null | sed -n 's/.*OU[ =]*\([[:alnum:]]\{10\}\).*/\1/p')}"; \
		if [ -n "$$team" ]; then \
			echo "==> Using local signing identity: $$identity"; \
			CODE_SIGNING_ALLOWED=YES \
			CODE_SIGN_IDENTITY="$$identity" \
			DEVELOPMENT_TEAM="$$team" \
			./scripts/package-dmg.sh; \
		else \
			echo "warning: signing identity found but Team ID could not be determined; building unsigned DMG" >&2; \
			./scripts/package-dmg.sh; \
		fi; \
	else \
		echo "warning: no Apple signing identity found; building unsigned DMG" >&2; \
		echo "         install an Apple Development certificate for local TCC testing" >&2; \
		./scripts/package-dmg.sh; \
	fi

release: archive-signed verify-signed
	@test -n "$${DEVELOPER_IDENTITY:-}" || { echo "error: DEVELOPER_IDENTITY is required for release" >&2; exit 2; }
	@test -n "$${DEVELOPMENT_TEAM:-}" || { echo "error: DEVELOPMENT_TEAM is required for release" >&2; exit 2; }
	@test -n "$${NOTARY_PROFILE:-}" || { echo "error: NOTARY_PROFILE is required for release" >&2; exit 2; }
	CODE_SIGNING_ALLOWED=YES \
	CODE_SIGN_IDENTITY="$${DEVELOPER_IDENTITY}" \
	DEVELOPMENT_TEAM="$${DEVELOPMENT_TEAM}" \
	PREBUILT_APP="$(RELEASE_APP)" \
		./scripts/package-dmg.sh
	NOTARY_INPUT="$(CURDIR)/dist/MacClippy.dmg" \
	STAPLE_TARGET="$(CURDIR)/dist/MacClippy.dmg" \
	EXPECTED_TEAM_ID="$${DEVELOPMENT_TEAM}" \
		./scripts/notarize.sh

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
	@test -n "$${DEVELOPMENT_TEAM:-}" || { echo "error: DEVELOPMENT_TEAM is required for signed verification" >&2; exit 2; }
	EXPECTED_TEAM_ID="$${DEVELOPMENT_TEAM}" ./scripts/verify-signed.sh "$(RELEASE_APP)"

notarize:
	@test -n "$${DEVELOPMENT_TEAM:-}" || { echo "error: DEVELOPMENT_TEAM is required for notarization verification" >&2; exit 2; }
	EXPECTED_TEAM_ID="$${DEVELOPMENT_TEAM}" ./scripts/notarize.sh

run: build
	@test -d "$(DEBUG_APP)" || { echo "error: expected app at $(DEBUG_APP)" >&2; exit 1; }
	open -n "$(DEBUG_APP)"

clean:
	@set -euo pipefail; \
	root="$$(pwd -P)"; \
	for target in "$(CURDIR)/.build" "$(CURDIR)/.swiftpm" "$(DERIVED_DATA)" "$(CURDIR)/$(PACKAGE_DIR)/.build" "$(CURDIR)/$(PACKAGE_DIR)/.swiftpm" "$(CURDIR)/$(PACKAGE_DIR)/build" "$(CURDIR)/build"; do \
		case "$$target" in \
			*"/../"*|*/..|*"/./"*|*/.) echo "error: refusing to clean a path with traversal components: $$target" >&2; exit 2 ;; \
			"$$root"|"$$root/$(PACKAGE_DIR)"|"$$root/.build"|"$$root/.build/"*|"$$root/.swiftpm"|"$$root/.swiftpm/"*|"$$root/$(PACKAGE_DIR)/.build"|"$$root/$(PACKAGE_DIR)/.build/"*|"$$root/$(PACKAGE_DIR)/.swiftpm"|"$$root/$(PACKAGE_DIR)/.swiftpm/"*|"$$root/$(PACKAGE_DIR)/build"|"$$root/$(PACKAGE_DIR)/build/"*|"$$root/build"|"$$root/build/"*) ;; \
			*) echo "error: refusing to clean path outside the repository build roots: $$target" >&2; exit 2 ;; \
		esac; \
		probe="$$target"; \
		while [ ! -d "$$probe" ] && [ "$$probe" != "/" ]; do probe="$${probe%/*}"; done; \
		resolved_probe="$$(cd -P "$$probe" && pwd)"; \
		case "$$resolved_probe" in \
			"$$root"|"$$root/$(PACKAGE_DIR)"|"$$root/.build"|"$$root/.build/"*|"$$root/.swiftpm"|"$$root/.swiftpm/"*|"$$root/$(PACKAGE_DIR)/.build"|"$$root/$(PACKAGE_DIR)/.build/"*|"$$root/$(PACKAGE_DIR)/.swiftpm"|"$$root/$(PACKAGE_DIR)/.swiftpm/"*|"$$root/$(PACKAGE_DIR)/build"|"$$root/$(PACKAGE_DIR)/build/"*|"$$root/build"|"$$root/build/"*) ;; \
			*) echo "error: refusing to clean through a symlink outside the repository build roots: $$target" >&2; exit 2 ;; \
		esac; \
	done; \
	rm -rf "$(CURDIR)/.build" "$(CURDIR)/.swiftpm" "$(DERIVED_DATA)" "$(CURDIR)/$(PACKAGE_DIR)/.build" "$(CURDIR)/$(PACKAGE_DIR)/.swiftpm" "$(CURDIR)/$(PACKAGE_DIR)/build" "$(CURDIR)/build"
