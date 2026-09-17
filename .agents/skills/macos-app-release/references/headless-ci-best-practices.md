# Headless macOS CI & Packaging Best Practices

Key architectural patterns derived from real-world macOS GitHub Actions pipelines:

## 1. Keychain Management in Headless Runners
- **The Problem**: In headless CI environments (SSH/GitHub Actions runners), accessing the system login keychain often triggers a macOS GUI authorization prompt dialog ("securityd wants to access..."), which hangs headless runners indefinitely until the step times out.
- **The Solution**:
  1. The pipeline creates an ephemeral keychain (`security create-keychain ...`) with an explicit timeout (`security set-keychain-settings -t 21600`).
  2. Uses `security set-key-partition-list -S apple-tool:,apple:,codesign: ...` to pre-authorize the codesign tool.
  3. In unit tests, mock the keychain layer (e.g. In-Memory keychain) during test execution to prevent test processes from touching login keychain items.

## 2. Packaging Archives with `ditto` vs `zip`
- Standard `zip` strips macOS extended file attributes, code signing resource forks, and symlinks.
- Always package macOS `.app` bundles using `ditto`:
  ```bash
  ditto -c -k --sequesterRsrc --keepParent "/path/to/App.app" "/path/to/App.zip"
  ```

## 3. High-Quality DMG Creation with `hdiutil`
- Create a clean staging directory containing the `.app` bundle and a symlink to `/Applications`:
  ```bash
  ln -s /Applications "${STAGING_DIR}/Applications"
  ```
- Use `hdiutil create` with `-format UDZO` (zlib compressed) and `-ov` (overwrite):
  ```bash
  hdiutil create -volname "${APP_NAME}" -srcfolder "${STAGING_DIR}" -ov -format UDZO "${DMG_PATH}"
  ```

## 4. Avoiding Headless RunLoop & Deadlock Traps in Tests
- Do not use `RunLoop.current.run(mode: .default, before: ...)` in headless macOS CI; it can trap in `mach_msg2_trap`.
- Avoid synchronous dispatch (`DispatchQueue.main.sync`) from background workers into the main queue when the main queue is waiting on test loop conditions.
