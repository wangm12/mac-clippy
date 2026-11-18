import AppKit
import MacClippyCore
import MacClippyPlatform
import SwiftUI
import XCTest

@testable import MacClippy

final class MacClippyHeaderRenderingTests: XCTestCase {
    @MainActor
    func testActualHeaderKeepsSearchCenteredWithEmptyAndOverflowingRanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacClippyHeader-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let runtime = try MacClippyRuntime(paths: MacClippyPaths(rootURL: root), enableSnippetExpansion: false)
        defer {
            runtime.closeForTesting()
            try? FileManager.default.removeItem(at: root)
        }
        let model = MacClippyDockModel(runtime: runtime)
        for count in [0, 1, 12] {
            model.pinboards = (0..<count).map {
                MacClippyPinboardEntry(board: Pinboard(name: "Long board name \($0) — 工作资料"), items: [])
            }
            model.query = count == 0 ? "type:text" : "invoice"
            if count == 12 {
                model.query += " type:text app:Safari after:2026-01-01 before:2026-12-31 has:name"
            }
            model.selectedTab = model.pinboards.last.map { .pinboard($0.id) } ?? .history
            model.captureStatus = .init(isPaused: count == 12, remainingIgnoredCopies: count == 1 ? 1 : 0)
            for width: CGFloat in [1024, 1280, 1440, 2560] {
                for dark in [false, true] {
                    try verifyHeader(model: model, width: width, dark: dark)
                }
            }
        }
    }

    @MainActor
    private func verifyHeader(model: MacClippyDockModel, width: CGFloat, dark: Bool) throws {
        let dock = MacClippyDockView(
            model: model, onClose: {}, onCreateSnippet: {}, onOpenSettings: {}, onEnterPickerMode: {},
            onPreview: {}, onSearchModeChange: { _ in }, onSearchCompositionChange: { _ in },
            onModalPresentationChange: { _ in }, onReduceMotionChange: { _ in }, onLayoutHeightChange: { _ in })
        let root = dock
            .environment(\.colorScheme, dark ? .dark : .light)
        let host = NSHostingView(rootView: root)
        let oldAppearance = NSApp.appearance
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        defer { NSApp.appearance = oldAppearance }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 360),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: width, height: 360)
        host.layoutSubtreeIfNeeded()
        let field = try XCTUnwrap(searchField(in: host))
        XCTAssertGreaterThanOrEqual(field.frame.width, 200, "Search width at \(width), dark=\(dark)")
        XCTAssertLessThanOrEqual(field.frame.width, 448, "Search must stay compact on wide screens")
        let frame = host.convert(field.bounds, from: field)
        // The native editor excludes the magnifier, filter chips and clear button.
        // It must remain inside the compact central search region even as those change.
        XCTAssertLessThan(abs(frame.midX - width / 2), 80,
                          "Search must remain centered regardless of ranges or capture status")
        XCTAssertGreaterThanOrEqual(frame.minX, width / 2 - 224)
        XCTAssertLessThanOrEqual(frame.maxX, width / 2 + 224)
        let filename = "macclippy-header-centered-\(model.pinboards.count)-\(Int(width))-\(dark ? "dark" : "light").png"
        let output = URL(fileURLWithPath: "/tmp/\(filename)")
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output)
    }

    @MainActor
    private func searchField(in view: NSView) -> MacClippyIMESearchField? {
        if let field = view as? MacClippyIMESearchField { return field }
        return view.subviews.lazy.compactMap { self.searchField(in: $0) }.first
    }

}
