# Settings Window Redesign

## Goal

Make the mac-clippy Settings surface feel like a native macOS preferences
window, open reliably from a menu-bar-only app, and give numeric retention
settings clear right-aligned controls.

## References and decisions

- Keep the native SwiftUI `Settings` scene rather than introducing a second
  preferences framework.
- Activate the accessory app before bringing Settings forward so the window
  can be shown from the menu bar and from a full-screen app.
- Configure the Settings window to move to the active Space and remain a
  normal, non-full-screen window. Do not use `fullScreenAuxiliary`: that would
  intentionally overlay the current full-screen app instead of switching to
  mac-clippy's regular settings window.
- Follow Apple's native settings density: sidebar navigation, compact detail
  sections, stable content surfaces, and system controls.
- Replace numeric `Stepper` controls with right-aligned, fixed-width numeric
  input controls. Preserve the existing `0` means Unlimited behavior and the
  current persisted keys/ranges.
- Remove the duplicate gear tap gesture so one click produces one Settings
  request.

## Layout

- Use a `NavigationSplitView` with `General` and `Shortcuts` sidebar items.
- Give the detail column a title, short explanation, and vertically scrolling
  grouped sections.
- Use a reusable settings row/card pattern with the description on the left
  and controls aligned to a shared trailing column on the right.
- Keep privacy, permissions, startup, and snippet behavior unchanged while
  improving hierarchy, spacing, labels, and inline error placement.
- Keep the existing shortcut recorder behavior and live registration path;
  only restyle its presentation if needed for the new row.

## Files

- `MacClippy/MacClippyApp.swift`: settings scene/window activation support if
  needed by the AppKit bridge.
- `MacClippy/MacClippySettings.swift`: complete visual/layout rewrite,
  numeric input controls, and settings-window configuration bridge.
- `MacClippy/MacClippyDock.swift`: one-shot Settings button action and stale
  comments.
- `project.yml`: add any new source file if the window bridge is split out.

## Verification

- Run `swift test --package-path MacClippyKit`.
- Run the full app `xcodebuild test` suite.
- Run the app build command.
- Manually smoke-test gear invocation from a normal desktop and while another
  app is full-screen; confirm the Settings window is normal-sized, frontmost,
  and not an overlay attached to the full-screen app.
