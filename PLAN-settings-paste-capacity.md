# Paste-Style Single-Page Settings

## Goal

Make Settings a single General page inspired by Paste: show history capacity
as a small number of clear retention choices, remove free-form numeric inputs,
and keep the dock shortcut on the same page.

## Decisions

- Remove `NavigationSplitView`, sidebar state, and the separate Shortcuts page.
- Keep a single native grouped `Form` with sections for History, Shortcut,
  Snippets, Permissions, Startup, and Privacy.
- The visible order is `History`, `Shortcut`, `Snippets`, `Permissions`,
  `Startup`, then `Privacy`; remove the Storage section from the visible page.
- Replace the editable maximum-age field with a discrete native slider:
  `Day`, `Week`, `Month`, and `Unlimited`.
- Map those choices to the existing `maxAgeDays` persistence key as `1`, `7`,
  `30`, and `0`. Keep the existing retention engine unchanged.
- Replace maximum-item and image-storage text fields with native menu pickers
  using fixed options. No free-form numeric input remains in Settings.
- Keep the existing shortcut recorder and live registration notifications, but
  place Toggle dock in the General page.
- When the gear is clicked, activate mac-clippy and explicitly make the native
  Settings window key and front whether it already exists or is being created.
- Keep privacy text inputs because exclusions are inherently user-authored
  patterns/identifiers; the capacity controls themselves have no text input.
- Use a narrower single-page Settings window suitable for the content and keep
  the existing normal-window/active-Space behavior.

## Verification

- Test the discrete capacity mapping and existing retention behavior.
- Run `swift test --package-path MacClippyKit`.
- Run the app build and full app test suite.
- Inspect the resulting single page for Paste-like hierarchy, no sidebar, no
  numeric input boxes, and right-aligned native controls.
