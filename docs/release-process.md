# CI and release process

## Required CI gate

`.github/workflows/ci.yml` is the required workflow. Release jobs query the Actions API for the workflow whose identity is `.github/workflows/ci.yml`, then match its workflow ID, path, and `head_sha` to the exact SHA checked out for the release build. The gate paginates the matching workflow-run list before selecting the most recently started attempt, with run number, attempt number, and creation time as tie-breakers. If the API's reported result count differs from the number of returned runs, the gate fails closed instead of making a decision from an incomplete or changing list. A rerun of an older run can therefore supersede an earlier success. A missing, queued, in-progress, canceled, failed, or otherwise non-successful latest attempt blocks packaging and publishing; an older success is not used around a newer failed attempt.

The release checkout and stable tag target are checked against `GITHUB_SHA`. The build receives an explicit marketing version and build version, and the finished app's `CFBundleShortVersionString` and `CFBundleVersion` are checked before packaging. The release workflow does not use a reusable workflow, so caller/callee concurrency cannot cancel the caller through a shared workflow-name group.

Ordinary App unit and Thread Sanitizer commands select `MacClippyTests` only. Scale jobs set both `MACCLIPPY_RUN_SCALE_TESTS=1` and `TEST_RUNNER_MACCLIPPY_RUN_SCALE_TESTS=1`, then require the named XCTest suite to report executed, passing tests with no skips. UI launch/termination tests belong in the separate E2E scheme and harness owned by the E2E workflow/documentation.

## Release identity and artifact names

- **Stable:** only a `vX.Y.Z` tag is accepted. `MARKETING_VERSION` and `CFBundleShortVersionString` equal `X.Y.Z`. `CFBundleVersion` encodes the GitHub Actions run number as three valid numeric components. DMG, ZIP, and checksum files are named `MacClippy-X.Y.Z.*`.
- **Nightly:** only a push to `main` is accepted. `MARKETING_VERSION` is `0.0.0`. `CFBundleVersion` encodes the first six hexadecimal characters of the source SHA as three numeric components. Artifact names include the first eight SHA characters and nightly release notes include the full SHA.
- Stable and nightly release attempts share the static `macclippy-release-artifacts` concurrency group with `cancel-in-progress: false`. The nightly ref update and nightly asset edits run inside this same group. `scripts/retarget-nightly-tag.sh` accepts only a main-branch event and the exact checked-out `GITHUB_SHA`; it can update only `refs/tags/nightly`. First creation uses a normal Git push, and an existing ref is replaced only with an explicit `--force-with-lease` for the observed old object ID. Repeating the same SHA is a no-op. The nightly path has no stable-tag input and never force-moves a `vX.Y.Z` tag. Nightly assets from older commits are removed before the current SHA's files are attached.
- `gh release edit --target` does not move an existing tag ref: GitHub documents [`target_commitish`](https://docs.github.com/en/rest/releases/releases#update-a-release) as unused when the tag already exists. The workflow updates `refs/tags/nightly` directly, then creates or edits the GitHub Release against that ref. On first release creation it uses [`--verify-tag`](https://cli.github.com/manual/gh_release_create) so release metadata cannot silently create a different tag target. Retargeting uses Git's explicit [`--force-with-lease`](https://git-scm.com/docs/git-push) to reject a concurrent change to the nightly ref.
- The required CI workflow has a 90-minute job timeout, while the release gate waits up to two hours for CI visibility and completion. The release job has a 180-minute timeout, leaving up to one hour after the gate for packaging and release work when the gate uses its full wait budget.
- The package script creates a DMG, ZIP, and SHA-256 checksum file. Code signing continues to use `MACOS_CERT_P12` and `MACOS_CERT_PASSWORD`; absent credentials produce unsigned output. The import script does not print the secrets.

`make release VERSION=X.Y.Z` creates and pushes a tag. It is a user-operated command and is not part of offline validation. Workflow and shell tests use mocked GitHub/Git commands and do not create tags or releases.

## Local cleanup and packaging

`make clean` removes the managed build caches, archives and test results while preserving `dist/` and review evidence. It does not remove clipboard history, pinboards, snippets, preferences or recovery backups. Remove disposable external DerivedData / isolated E2E fixtures separately after their processes have exited; do not clear unrelated projects' global Xcode or SwiftPM caches.

Spotlight can discover `.app` bundles inside upgrade backups as separate applications. Store backup applications as verified ZIP archives, keep their data backups, and eject old installer volumes. After removing unused development bundles, run:

```sh
python3 scripts/refresh-app-registration.py         # Preview only
python3 scripts/refresh-app-registration.py --apply # Keep the installed copy registered
```

The script targets only MacClippy, its isolated E2E app and UI test runner. It verifies the installed bundle identifier, unregisters their other paths (including stale paths), registers `/Applications/MacClippy.app`, and checks the resulting registrations. It never resets the entire Launch Services database. Existing unarchived copies can be indexed again, so archive or remove those copies first. Spotlight results may take time to refresh.

For a local package with the existing signing identity, use `make dmg`. To stamp source provenance before signing, first run `make build-release-unsigned MARKETING_VERSION=1.0.0 CURRENT_PROJECT_VERSION=YYYY.MM.DD`, add the source revision to the built app's Info.plist, sign and verify it, then package that app with `PREBUILT_APP` under the repository's `build/` directory. Verify the mounted DMG's app signature and version before installing. Keep only the distribution artifacts after running `make clean`; unregister the removed build paths again. Local packaging does not create a stable release tag or publish a GitHub Release.

## Minimum macOS runtime gate

The required CI workflow currently runs its package and App regression suites on macOS 26. The project sets `MACOSX_DEPLOYMENT_TARGET=14.0`, but that only checks compilation against the declared deployment target; it does not demonstrate runtime behavior on macOS 14. **macOS 14 runtime acceptance has not been run.** No macOS 14 test machine or compatible hosted CI runner is currently configured, and no remote environment is provisioned by this workflow.

The former `macos-14-arm64` build-and-test job was removed because the official image currently tops out at Xcode 16.2 / Swift 6.0, while the checked-in GRDB 7.11.1 pin requires Swift tools 6.1. That job could not compile the pinned dependency without changing the toolchain or downgrading dependencies, so it was not a valid required check. See GitHub's [macOS 14 ARM64 runner image](https://github.com/actions/runner-images/blob/main/images/macos/macos-14-arm64-Readme.md), Apple's [Xcode system requirements](https://developer.apple.com/xcode/system-requirements), and the pinned [GRDB 7.11.1 manifest](https://github.com/groue/GRDB.swift/blob/v7.11.1/Package.swift). A future macOS 14 acceptance run needs an actual compatible macOS 14 environment; compiling on a newer host with a 14.0 deployment target is not equivalent.

The app metadata validator enforces Apple's documented `CFBundleVersion` component bounds: a nonzero first integer of up to four digits and up to two additional components of up to two digits each ([Apple bundle build string](https://developer.apple.com/help/glossary/)).

The local development host used for this Phase 5 work is macOS 26.6.2 with Xcode 26.4.1; no local macOS 14 target is configured.
