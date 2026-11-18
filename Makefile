# Make runs through Bash because several recipes rely on pipefail and arrays.
SHELL := /bin/bash
.DEFAULT_GOAL := build

# Project and toolchain
PROJECT := MacClippy.xcodeproj
SCHEME := MacClippy
PACKAGE_DIR := MacClippyKit
DESTINATION := platform=macOS,arch=arm64
TOOLS_DEFAULT_PARENT := $(if $(RUNNER_TEMP),$(RUNNER_TEMP),$(if $(TMPDIR),$(TMPDIR),/tmp))
PINNED_TOOLS_PREFIX ?= $(if $(MACCLIPPY_TOOLS_PREFIX),$(MACCLIPPY_TOOLS_PREFIX),$(TOOLS_DEFAULT_PARENT)/macclippy-tools)
PINNED_TOOLS_BIN := $(PINNED_TOOLS_PREFIX)/bin
export PATH := $(PINNED_TOOLS_BIN):$(PATH)

# Build and test output paths
DERIVED_DATA ?= $(CURDIR)/.build/DerivedData
DEBUG_APP := $(DERIVED_DATA)/Build/Products/Debug/MacClippy.app
ARCHIVE_PATH ?= $(CURDIR)/build/archives/MacClippy.xcarchive
RELEASE_DERIVED_DATA ?= $(CURDIR)/build/derived-data
TEST_RESULTS_DIR := $(CURDIR)/build/test-results
RELEASE_APP := $(ARCHIVE_PATH)/Products/Applications/MacClippy.app
RELEASE_UNSIGNED_APP := $(RELEASE_DERIVED_DATA)/Build/Products/Release/MacClippy.app
NOTARY_ARTIFACT_NAME := $(if $(strip $(ARTIFACT_NAME)),$(ARTIFACT_NAME),MacClippy)

# Shared Xcode arguments keep build, test, and release targets aligned.
XCODEBUILD_COMMON_FLAGS := \
	-project "$(PROJECT)" \
	-scheme "$(SCHEME)" \
	-skipPackagePluginValidation

XCODEBUILD_FLAGS := \
	$(XCODEBUILD_COMMON_FLAGS) \
	-configuration Debug \
	-destination "$(DESTINATION)" \
	-derivedDataPath "$(DERIVED_DATA)" \
	CODE_SIGNING_ALLOWED=NO

# ci-full shares SwiftPM and Xcode build caches across its sequential checks.
.PHONY: help \
	ensure-pinned-tools verify-pinned-tools generate build \
	test test-scripts test-scale test-stress test-tsan test-app-tsan \
	lint ci-fast ci-full ci \
	dmg signing-cert release release-local build-release-unsigned \
	verify-build-metadata archive-signed verify-signed notarize \
	run clean
.NOTPARALLEL: ci-full

help:
	@printf '%s\n' 'MacClippy development targets:'
	@printf '  %-24s %s\n' \
		help 'Show available targets' \
		ensure-pinned-tools 'Install pinned XcodeGen and SwiftLint when needed' \
		verify-pinned-tools 'Check pinned XcodeGen and SwiftLint versions' \
		generate 'Generate the Xcode project from project.yml' \
		build 'Build the Debug app' \
		test 'Run Package and MacClippyTests unit tests' \
		test-scripts 'Run build/release shell-script tests' \
		test-scale 'Run explicitly opted-in scale tests' \
		test-stress 'Run lifecycle stress tests' \
		test-tsan 'Run Package tests with Thread Sanitizer' \
		test-app-tsan 'Run MacClippyTests with Thread Sanitizer' \
		lint 'Run SwiftLint against the checked-in baseline' \
		ci-fast 'Run lint, unit tests, and a Debug build' \
		ci-full 'Run all local test and release-build checks' \
		ci 'Run the full local CI check sequence' \
		dmg 'Build a DMG, ZIP, and SHA-256 manifest' \
		signing-cert 'Create the local MacClippy signing certificate' \
		'release VERSION=x.y.z' 'Create a versioned GitHub release' \
		release-local 'Sign, archive, package, and notarize locally' \
		build-release-unsigned 'Build and validate an unsigned Release app' \
		verify-build-metadata 'Validate Debug app version metadata' \
		archive-signed 'Create a signed Xcode archive' \
		verify-signed 'Verify the signed archive against the team ID' \
		notarize 'Submit or staple the configured release artifact' \
		run 'Build and open the Debug app' \
		clean 'Remove known outputs; preserve dist and review evidence'

ensure-pinned-tools:
	@if ! ./scripts/verify-tool-versions.sh >/dev/null 2>&1; then \
		MACCLIPPY_TOOLS_PREFIX="$(PINNED_TOOLS_PREFIX)" ./scripts/install-pinned-tools.sh; \
	fi
	./scripts/verify-tool-versions.sh

verify-pinned-tools:
	./scripts/verify-tool-versions.sh

generate: ensure-pinned-tools
	xcodegen generate

build: generate
	xcodebuild $(XCODEBUILD_FLAGS) build

test: generate test-scripts
	swift test --package-path "$(PACKAGE_DIR)"
	xcodebuild $(XCODEBUILD_FLAGS) -only-testing:MacClippyTests test

test-scripts:
	./scripts/clean-build-test.sh
	./scripts/install-pinned-tools-test.sh
	./scripts/select-codesign-identity-test.sh

test-scale: generate
	@set -euo pipefail; \
	results_dir="$(TEST_RESULTS_DIR)"; \
	mkdir -p "$$results_dir"; \
	run_id="$$(date +%Y%m%d%H%M%S)-$$$$"; \
	package_log="$$results_dir/scale-package-$$run_id.log"; \
	MACCLIPPY_RUN_SCALE_TESTS=1 TEST_RUNNER_MACCLIPPY_RUN_SCALE_TESTS=1 \
		swift test --package-path "$(PACKAGE_DIR)" --filter MacClippyScaleTests 2>&1 | tee "$$package_log"; \
	./scripts/assert-opt-in-xctest-log.sh "$$package_log" MacClippyScaleTests
	@set -euo pipefail; \
	results_dir="$(TEST_RESULTS_DIR)"; \
	mkdir -p "$$results_dir"; \
	run_id="$$(date +%Y%m%d%H%M%S)-$$$$"; \
	result_bundle="$$results_dir/scale-app-$$run_id.xcresult"; \
	log_file="$$results_dir/scale-app-$$run_id.log"; \
	MACCLIPPY_RUN_SCALE_TESTS=1 TEST_RUNNER_MACCLIPPY_RUN_SCALE_TESTS=1 \
		xcodebuild test $(XCODEBUILD_COMMON_FLAGS) \
		-configuration Debug -destination "$(DESTINATION)" \
		-derivedDataPath "$(DERIVED_DATA)/Scale" -resultBundlePath "$$result_bundle" \
		-parallel-testing-enabled NO -maximum-parallel-testing-workers 1 \
		-only-testing:MacClippyTests/MacClippyRuntimeSearchScaleTests \
		CODE_SIGNING_ALLOWED=NO 2>&1 | tee "$$log_file"; \
	./scripts/assert-opt-in-xctest-log.sh "$$log_file" MacClippyRuntimeSearchScaleTests

test-stress: generate
	MACCLIPPY_RUN_STRESS_TESTS=1 swift test --package-path "$(PACKAGE_DIR)" --filter MacClippyLifecycleStressTests

test-tsan: generate
	swift test --package-path "$(PACKAGE_DIR)" --sanitize=thread

test-app-tsan: generate
	@set -euo pipefail; \
	results_dir="$(TEST_RESULTS_DIR)"; \
	mkdir -p "$$results_dir"; \
	run_id="$$(date +%Y%m%d%H%M%S)-$$$$"; \
	result_bundle="$$results_dir/app-tsan-$$run_id.xcresult"; \
	log_file="$$results_dir/app-tsan-$$run_id.log"; \
	xcodebuild test $(XCODEBUILD_COMMON_FLAGS) \
		-configuration Debug -destination "$(DESTINATION)" \
		-derivedDataPath "$(DERIVED_DATA)/AppTSan" \
		-resultBundlePath "$$result_bundle" \
		-parallel-testing-enabled NO -maximum-parallel-testing-workers 1 \
		-only-testing:MacClippyTests \
		-enableThreadSanitizer YES \
		CODE_SIGNING_ALLOWED=NO 2>&1 | tee "$$log_file"

lint: ensure-pinned-tools
	./scripts/lint.sh

ci-fast: generate lint test-scripts
	swift test --package-path "$(PACKAGE_DIR)"
	xcodebuild $(XCODEBUILD_FLAGS) build
	xcodebuild $(XCODEBUILD_FLAGS) -only-testing:MacClippyTests test

ci-full: ci-fast test-scale test-stress test-tsan test-app-tsan build-release-unsigned

ci: ci-full

signing-cert:
	./scripts/make-signing-cert.sh

dmg: ensure-pinned-tools
	@set -euo pipefail; \
	eval "$$(./scripts/resolve-dmg-signing.sh)"; \
	if [ -n "$${CODE_SIGN_IDENTITY:-}" ] && [ -n "$${DEVELOPMENT_TEAM:-}" ]; then \
		echo "==> Using signing identity: $$CODE_SIGN_IDENTITY"; \
		CODE_SIGNING_ALLOWED=YES \
		CODE_SIGN_IDENTITY="$$CODE_SIGN_IDENTITY" \
		DEVELOPMENT_TEAM="$$DEVELOPMENT_TEAM" \
		MARKETING_VERSION="$(MARKETING_VERSION)" \
		CURRENT_PROJECT_VERSION="$(CURRENT_PROJECT_VERSION)" \
		ARTIFACT_NAME="$(ARTIFACT_NAME)" \
		VOLUME_NAME="$(VOLUME_NAME)" \
		./scripts/package-dmg.sh; \
	else \
		echo "warning: building unsigned DMG" >&2; \
		MARKETING_VERSION="$(MARKETING_VERSION)" \
		CURRENT_PROJECT_VERSION="$(CURRENT_PROJECT_VERSION)" \
		ARTIFACT_NAME="$(ARTIFACT_NAME)" \
		VOLUME_NAME="$(VOLUME_NAME)" \
		./scripts/package-dmg.sh; \
	fi

release:
	@./scripts/release.sh "$(VERSION)"

release-local: archive-signed
	@test -n "$${DEVELOPER_IDENTITY:-}" || { echo "error: DEVELOPER_IDENTITY is required for release" >&2; exit 2; }
	@test -n "$${DEVELOPMENT_TEAM:-}" || { echo "error: DEVELOPMENT_TEAM is required for release" >&2; exit 2; }
	@test -n "$${NOTARY_PROFILE:-}" || { echo "error: NOTARY_PROFILE is required for release" >&2; exit 2; }
	EXPECTED_TEAM_ID="$${DEVELOPMENT_TEAM}" ./scripts/verify-signed.sh "$(RELEASE_APP)"
	CODE_SIGNING_ALLOWED=YES \
	CODE_SIGN_IDENTITY="$${DEVELOPER_IDENTITY}" \
	DEVELOPMENT_TEAM="$${DEVELOPMENT_TEAM}" \
	MARKETING_VERSION="$(MARKETING_VERSION)" \
	CURRENT_PROJECT_VERSION="$(CURRENT_PROJECT_VERSION)" \
	ARTIFACT_NAME="$(ARTIFACT_NAME)" \
	VOLUME_NAME="$(VOLUME_NAME)" \
	PREBUILT_APP="$(RELEASE_APP)" \
		./scripts/package-dmg.sh
	NOTARY_INPUT="$(CURDIR)/dist/$(NOTARY_ARTIFACT_NAME).dmg" \
	STAPLE_TARGET="$(CURDIR)/dist/$(NOTARY_ARTIFACT_NAME).dmg" \
	EXPECTED_TEAM_ID="$${DEVELOPMENT_TEAM}" \
		./scripts/notarize.sh

build-release-unsigned: generate
	xcodebuild $(XCODEBUILD_COMMON_FLAGS) \
		-configuration Release -destination "$(DESTINATION)" \
		-derivedDataPath "$(RELEASE_DERIVED_DATA)" \
		CODE_SIGNING_ALLOWED=NO \
		$(if $(MARKETING_VERSION),MARKETING_VERSION="$(MARKETING_VERSION)") \
		$(if $(CURRENT_PROJECT_VERSION),CURRENT_PROJECT_VERSION="$(CURRENT_PROJECT_VERSION)") \
		ENABLE_HARDENED_RUNTIME=YES build
	EXPECTED_MARKETING_VERSION="$(MARKETING_VERSION)" \
	EXPECTED_BUILD_VERSION="$(CURRENT_PROJECT_VERSION)" \
		./scripts/verify-build-metadata.sh "$(RELEASE_UNSIGNED_APP)"

verify-build-metadata:
	./scripts/verify-build-metadata.sh "$(DEBUG_APP)"

archive-signed: generate
	DEVELOPER_IDENTITY="$${DEVELOPER_IDENTITY:-}" \
	DEVELOPMENT_TEAM="$${DEVELOPMENT_TEAM:-}" \
	MARKETING_VERSION="$(MARKETING_VERSION)" \
	CURRENT_PROJECT_VERSION="$(CURRENT_PROJECT_VERSION)" \
	ARCHIVE_PATH="$(ARCHIVE_PATH)" \
		./scripts/archive-signed.sh

verify-signed:
	@test -n "$${DEVELOPMENT_TEAM:-}" || { echo "error: DEVELOPMENT_TEAM is required for signed verification" >&2; exit 2; }
	EXPECTED_TEAM_ID="$${DEVELOPMENT_TEAM}" ./scripts/verify-signed.sh "$(RELEASE_APP)"

notarize:
	@test -n "$${DEVELOPMENT_TEAM:-}" || { echo "error: DEVELOPMENT_TEAM is required for notarization verification" >&2; exit 2; }
	NOTARY_INPUT="$(CURDIR)/dist/$(NOTARY_ARTIFACT_NAME).dmg" \
	STAPLE_TARGET="$(CURDIR)/dist/$(NOTARY_ARTIFACT_NAME).dmg" \
	EXPECTED_TEAM_ID="$${DEVELOPMENT_TEAM}" \
		./scripts/notarize.sh

run: build
	@test -d "$(DEBUG_APP)" || { echo "error: expected app at $(DEBUG_APP)" >&2; exit 1; }
	@killall MacClippy 2>/dev/null || true
	open -n "$(DEBUG_APP)"

clean:
	ROOT_DIR="$(CURDIR)" ./scripts/clean-build.sh
