import XCTest

@testable import MacClippy
import MacClippyCore

final class MacClippyDockCategoryTests: XCTestCase {
    func testCategoryFooterShowsAtMostTwoCategoriesAndReportsOverflow() {
        let categories = [
            category(name: "Work"),
            category(name: "API"),
            category(name: "Personal")
        ]

        XCTAssertEqual(
            MacClippyDockCardCategoryPolicy.visibleCategories(from: categories).map(\.name),
            ["Work", "API"]
        )
        XCTAssertEqual(MacClippyDockCardCategoryPolicy.overflowCount(for: categories), 1)
    }

    func testCategoryIndicatorShowsOnAllTabOnlyWhenTagged() {
        let tagged = [category(name: "grok_api")]
        XCTAssertTrue(
            MacClippyDockCardCategoryPolicy.shouldShowIndicator(
                categories: tagged,
                selectedTab: .history
            )
        )
        XCTAssertFalse(
            MacClippyDockCardCategoryPolicy.shouldShowIndicator(
                categories: [],
                selectedTab: .history
            )
        )
        XCTAssertFalse(
            MacClippyDockCardCategoryPolicy.shouldShowIndicator(
                categories: tagged,
                selectedTab: .pinboard(RecordID.generate())
            )
        )
        XCTAssertFalse(
            MacClippyDockCardCategoryPolicy.shouldShowIndicator(
                categories: tagged,
                selectedTab: .snippets
            )
        )
    }

    func testCategoryFooterDoesNotRenderWhenThereAreNoCategories() {
        XCTAssertTrue(MacClippyDockCardCategoryPolicy.visibleCategories(from: []).isEmpty)
        XCTAssertEqual(MacClippyDockCardCategoryPolicy.overflowCount(for: []), 0)
        XCTAssertNil(MacClippyDockCardCategoryPolicy.accessibilitySummary(for: []))
    }

    func testCategoryAccessibilityIncludesCategoriesHiddenByOverflow() {
        let categories = [category(name: "Work"), category(name: "API"), category(name: "Personal")]

        XCTAssertEqual(
            MacClippyDockCardCategoryPolicy.accessibilitySummary(for: categories),
            "Categories: Work, API, Personal"
        )
    }

    @MainActor
    func testCategoryMembershipIndexIncludesAllBoardsInBoardOrder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacClippyDockCategoryTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let runtime = try MacClippyRuntime(paths: try MacClippyPaths(rootURL: root))
        let model = MacClippyDockModel(runtime: runtime)
        let itemID = RecordID.generate()
        let first = Pinboard(id: RecordID.generate(), name: "Work", itemIDs: [itemID])
        let second = Pinboard(id: RecordID.generate(), name: "API", itemIDs: [itemID])
        model.pinboards = [
            MacClippyPinboardEntry(board: first, items: []),
            MacClippyPinboardEntry(board: second, items: [])
        ]

        XCTAssertEqual(model.categories(for: itemID).map(\.name), ["Work", "API"])
    }

    func testChangeColorMenuShowsNamedSwatchesInsteadOfHexCodes() throws {
        let menus = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("MacClippy/MacClippyDockCardMenus.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(menus.contains("MacClippyCategoryColorPolicy.displayName"))
        XCTAssertTrue(menus.contains("MacClippyCategoryColorSwatch.image"))
        XCTAssertFalse(menus.contains("Text(color)"))

        let swatch = MacClippyCategoryColorSwatch.image(for: "#0A84FF")
        XCTAssertEqual(swatch.size, NSSize(width: 14, height: 14))
        XCTAssertFalse(swatch.isTemplate)
    }

    private func category(name: String) -> MacClippyDockCategoryPresentation {
        MacClippyDockCategoryPresentation(
            id: RecordID.generate(),
            name: name,
            colorHex: "#0A84FF"
        )
    }
}
