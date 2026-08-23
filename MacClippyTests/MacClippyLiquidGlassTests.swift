import AppKit
import XCTest

@testable import MacClippy

final class MacClippyLiquidGlassTests: XCTestCase {
    func testConcentricRadiusIsFallbackOnlyAndNeverDropsBelowEight() {
        XCTAssertEqual(MacClippyConcentricRadius.minimum, 8)
        XCTAssertEqual(MacClippyConcentricRadius.inner(outer: 28, inset: 12), 16)
        XCTAssertEqual(MacClippyConcentricRadius.inner(outer: 12, inset: 10), 8)
        XCTAssertEqual(MacClippyConcentricRadius.inner(outer: 8, inset: 20), 8)
    }

    func testPanelGlassUsesAppleRegularStyle() {
        XCTAssertEqual(MacClippyDockBackdropHolePolicy.panelCornerRadius, 28)
        XCTAssertEqual(MacClippyDockGlassStyle.regularName, "regular")
    }

    @MainActor
    func testPanelGlassYieldsToReduceTransparency() {
        let view = MacClippyDockBackdropView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        view.applyTransparencyPolicy(reduceTransparency: false)
        view.layoutSubtreeIfNeeded()
        XCTAssertTrue(view.isShowingGlass)
        XCTAssertFalse(view.isShowingSolidFill)

        view.applyTransparencyPolicy(reduceTransparency: true)
        view.layoutSubtreeIfNeeded()
        XCTAssertFalse(view.isShowingGlass)
        XCTAssertTrue(view.isShowingSolidFill)
    }

    @MainActor
    func testPanelGlassEmbedsForegroundAsContentView() {
        let view = MacClippyDockBackdropView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let foreground = NSView(frame: .zero)
        view.embedForeground(foreground)
        view.applyTransparencyPolicy(reduceTransparency: false)
        view.layoutSubtreeIfNeeded()
        if #available(macOS 26, *) {
            XCTAssertTrue(view.embedsForegroundInGlass)
        } else {
            XCTAssertEqual(foreground.superview, view)
        }

        view.applyTransparencyPolicy(reduceTransparency: true)
        view.layoutSubtreeIfNeeded()
        XCTAssertFalse(view.embedsForegroundInGlass)
        XCTAssertEqual(foreground.superview, view)
    }

    func testSettingsSidebarHasFourPagesAndGeneralKeepsHistoryPlusShortcut() throws {
        XCTAssertEqual(
            MacClippySettingsPage.allCases.map(\.rawValue),
            ["general", "privacy", "permissions", "advanced"]
        )
        XCTAssertEqual(MacClippySettingsMetrics.minWidth, 720)
        XCTAssertEqual(MacClippySettingsMetrics.minSize, NSSize(width: 720, height: 520))
        XCTAssertGreaterThanOrEqual(
            MacClippySettingsMetrics.minWidth,
            MacClippySettingsMetrics.sidebarIdealWidth
                + MacClippySettingsMetrics.historyPickerWidth
                + 180
        )

        let settings = try appSource(named: "MacClippySettings.swift")
        XCTAssertTrue(settings.contains("NavigationSplitView"))
        XCTAssertTrue(settings.contains("formStyle(.grouped)"))
        XCTAssertFalse(settings.contains("windowBackgroundColor"))
        XCTAssertFalse(settings.contains("settingsHeader"))

        let sections = try appSource(named: "MacClippySettings+Sections.swift")
        XCTAssertTrue(sections.contains("historySection"))
        XCTAssertTrue(sections.contains("shortcutSection"))
        XCTAssertTrue(sections.contains("Pause capture"))
        XCTAssertFalse(sections.contains("isAdvancedExpanded"))
        XCTAssertTrue(sections.contains(".frame(height: 76)"))
        XCTAssertTrue(sections.contains("MacClippySettingsMetrics.historyPickerWidth"))

        let advanced = try appSource(named: "MacClippySettings+Maintenance.swift")
        XCTAssertTrue(advanced.contains("advancedSection"))
        XCTAssertFalse(advanced.contains("DisclosureGroup"))
        XCTAssertFalse(advanced.contains("isAdvancedExpanded"))
    }

    func testSourceAppIconRendersDefaultAppearanceAtBadgeSize() throws {
        let source = try appSource(named: "MacClippySourceAppPresentation.swift")
        XCTAssertTrue(source.contains("MacClippySourceAppIcon"))
        XCTAssertTrue(source.contains("NSAppearance(named: .aqua)"))
        XCTAssertTrue(source.contains("sourceBadgeSize"))

        let cardLabel = try appSource(named: "MacClippyClipboardCardLabel.swift")
        XCTAssertTrue(cardLabel.contains("colorScheme, .light"))
        XCTAssertTrue(cardLabel.contains("MacClippyMotion.hoverScale"))

        let icon = NSImage(size: NSSize(width: 256, height: 256))
        let prepared = MacClippySourceAppIcon.prepared(
            icon,
            pointSize: MacClippyDockCardMetrics.sourceBadgeSize
        )
        XCTAssertEqual(prepared.size.width, MacClippyDockCardMetrics.sourceBadgeSize)
        XCTAssertEqual(prepared.size.height, MacClippyDockCardMetrics.sourceBadgeSize)
    }

    func testCardSourcesStayOffGlass() throws {
        let cardLabel = try appSource(named: "MacClippyClipboardCardLabel.swift")
        XCTAssertFalse(cardLabel.contains("glassEffect"))
        XCTAssertFalse(cardLabel.contains("buttonStyle(.glass"))

        let card = try appSource(named: "MacClippyDockCard.swift")
        XCTAssertFalse(card.contains("glassEffect"))
        XCTAssertFalse(card.contains("buttonStyle(.glass"))
        XCTAssertTrue(card.contains("MacClippyCardButtonStyle()"))

        let snippets = try appSource(named: "MacClippyDockCardContent.swift")
        XCTAssertTrue(snippets.contains("MacClippySnippetHoverChrome"))
        XCTAssertTrue(snippets.contains("MacClippyDockCardHoverChrome"))
        XCTAssertTrue(snippets.contains("MacClippyMotion.hoverScale"))
    }

    func testDockNavSourcesUsePieceGlassAndKeepCarouselEdgeFade() throws {
        let dockView = try appSource(named: "MacClippyDockView.swift")
        XCTAssertFalse(dockView.contains("ultraThinMaterial"))
        XCTAssertTrue(dockView.contains("MacClippyDockCardWell"))
        XCTAssertFalse(dockView.contains("wellColor"))

        let theme = try appSource(named: "MacClippyDockTheme.swift")
        XCTAssertTrue(theme.contains("contentTextColor: Color { textColor }"))
        XCTAssertFalse(theme.contains("contentTextColor: Color { Color.primary }"))
        XCTAssertFalse(dockView.contains("preferredColorScheme(.dark)"))

        let search = try appSource(named: "MacClippyDockView+HeaderSearch.swift")
        XCTAssertFalse(search.contains("lineWidth: 3"))
        XCTAssertTrue(search.contains("MacClippyDockTheme.textColor"))
        XCTAssertTrue(search.contains("MacClippyDockTheme.mutedColor"))
        XCTAssertTrue(search.contains("macClippySearchGlass"))
        XCTAssertTrue(search.contains("hoveredSearch"))
        XCTAssertTrue(search.contains("interactiveHoverBorder"))
        XCTAssertTrue(search.contains("interactiveFocusBorder"))
        XCTAssertFalse(search.contains("Color.primary.opacity(0.28)"))

        let filters = try appSource(named: "MacClippyDockView+FilterDrop.swift")
        XCTAssertTrue(filters.contains("MacClippyDockTheme.textColor"))
        XCTAssertTrue(filters.contains(".body.weight"))
        XCTAssertTrue(filters.contains("macClippyFilterChipStyle"))
        XCTAssertFalse(filters.contains("prominent: selected"))
        XCTAssertTrue(filters.contains("pillRestBorder"))
        XCTAssertTrue(filters.contains("macClippyGlassEffectID(\"newCategory\""))
        XCTAssertFalse(filters.contains("isHovered ? MacClippyMotion.hoverScale"))
        XCTAssertFalse(filters.contains("isHovered ? 1 : 0"))
        XCTAssertFalse(filters.contains("value: isHovered"))
        XCTAssertTrue(filters.contains("MacClippyDockHoverPolicy.shouldApplyHover"))
        XCTAssertTrue(filters.contains("transaction.animation = nil"))

        let hover = try appSource(named: "MacClippyDockView.swift")
        XCTAssertTrue(hover.contains("hoverAnimation"))
        XCTAssertTrue(hover.contains("cardBorderInset"))

        let panel = try appSource(named: "MacClippyDockPanel.swift")
        XCTAssertTrue(panel.contains("NSGlassEffectView"))
        XCTAssertTrue(panel.contains(".regular"))
        XCTAssertTrue(panel.contains("embedForeground"))
        XCTAssertTrue(panel.contains("glass.contentView = foreground"))
        XCTAssertFalse(panel.contains("NSAppearance(named: .darkAqua)"))
        XCTAssertTrue(panel.contains("override var isOpaque: Bool { false }"))
        XCTAssertTrue(panel.contains("makeTransparent()"))

        let carousel = try appSource(named: "MacClippyDockView+CarouselModal.swift")
        XCTAssertTrue(carousel.contains("carouselEdgeFade"))

        let actionBar = try appSource(named: "MacClippyDockActionBar.swift")
        XCTAssertTrue(actionBar.contains("macClippyGlassButtonStyle") || actionBar.contains("buttonStyle(.glass"))
        XCTAssertTrue(actionBar.contains("glassProminent") || actionBar.contains("macClippyGlassProminentButtonStyle"))

        let preview = try appSource(named: "MacClippyDockPreview.swift")
        XCTAssertTrue(preview.contains("previewSurfaceColor"))
        XCTAssertFalse(preview.contains("macClippyFloatingGlass"))
        XCTAssertFalse(preview.contains("ultraThinMaterial"))
    }

    private func appSource(named fileName: String) throws -> String {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("MacClippy")
        return try String(contentsOf: sourceRoot.appendingPathComponent(fileName), encoding: .utf8)
    }
}
