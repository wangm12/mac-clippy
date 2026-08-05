# Apple-Native Settings Redesign

## Goal

Replace the custom card-based Settings detail UI with the visual language of
native macOS settings surfaces: a system sidebar, a grouped `Form`, native
section rows, and one consistent trailing control column.

## Design decisions

- Keep the existing SwiftUI `Settings` scene and the working normal-window /
  active-Space bridge.
- Keep `NavigationSplitView` for General and Shortcuts navigation, but remove
  the custom rounded section-card shells and oversized page-header treatment.
- Use native `Form` + `.formStyle(.grouped)` in each detail page. Native rows,
  separators, system background colors, and standard controls should carry the
  hierarchy instead of custom dashboard chrome.
- Use compact page titles and short explanatory subtitles; avoid repeating the
  section description in every row.
- Use `LabeledContent` for rows so labels stay on the leading side and values /
  controls share Apple's trailing alignment behavior.
- Remove the redundant `NavigationSplitView` sidebar toggle from the small,
  fixed settings navigator; this surface is a two-item preferences panel, not
  a document browser that needs collapsible navigation.
- Give the sidebar a stable native-width column so labels do not feel cramped.
- Keep numeric fields as validated input boxes, with the value and unit in a
  fixed trailing group. Preserve all current keys, ranges, and 0/Unlimited
  semantics.
- Preserve all current settings actions, hotkey notifications, Space handling,
  and reduced-motion behavior.

## Files

- `MacClippy/MacClippySettings.swift`: replace custom section/card components
  with native Form-based detail pages and native-aligned rows.
- `MacClippy/MacClippyDock.swift`: retain the fixed Settings invocation and
  dock-close sequencing.
- `MacClippyTests/MacClippyMotionTests.swift`: retain numeric policy tests and
  add only focused coverage if the refactor changes testable behavior.

## Verification

- `PKG_CONFIG_PATH="/opt/homebrew/opt/libarchive/lib/pkgconfig" swift test --package-path MacClippyKit`
- `xcodebuild ... build`
- `xcodebuild test ...`
- Review the resulting view for native density: no nested custom cards,
  aligned controls, readable form sections, and no loss of existing settings.
