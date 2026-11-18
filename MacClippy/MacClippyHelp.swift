import AppKit
import MacClippyPlatform

@MainActor
final class MacClippyHelpWindow {
    static let shared = MacClippyHelpWindow()
    private var window: NSWindow?

    func present(defaults: UserDefaults = .standard) {
        let window = window ?? NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 590),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Shortcuts & Search Help"
        window.isReleasedWhenClosed = false
        window.contentView = Self.makeContentView(defaults: defaults)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    static func makeContentView(defaults: UserDefaults) -> NSScrollView {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 540, height: 590))
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        let textView = NSTextView(frame: scrollView.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 24, height: 24)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityLabel("Shortcuts and search help")
        textView.textStorage?.setAttributedString(MacClippyHelpContent.document(defaults: defaults))
        scrollView.documentView = textView
        return scrollView
    }
}

@MainActor
enum MacClippyHelpContent {
    static func document(defaults: UserDefaults) -> NSAttributedString {
        let shortcut = MacClippyGlobalHotKeyDescriptor.load(from: defaults).symbolicDisplay
        let result = NSMutableAttributedString(string: "")
        append("Find it. Confirm it. Reuse it.\n\n", to: result, font: .systemFont(ofSize: 20, weight: .semibold))
        append("Type to search. Return in search enters the results and keeps your query. "
            + "Use the arrow keys to choose an item, then Return in results pastes it.\n\n", to: result)
        append("Copy and paste\n", to: result, font: .systemFont(ofSize: 15, weight: .semibold))
        for row in [
            (shortcut, "Open or close clipboard history"),
            ("Click", "Select an item"), ("Double-click", "Copy and close"),
            ("⌘C", "Copy and keep the panel open"), ("Return in results", "Paste the selected result"),
            ("Shift-Return", "Switch between formatted and plain text"),
            ("Space in results", "Preview the selected result"), ("⌘1–⌘9", "Paste the numbered item")
        ] { append("\(row.0) — \(row.1)\n", to: result) }
        append("\nNavigation and editing\n", to: result, font: .systemFont(ofSize: 15, weight: .semibold))
        for row in [
            ("⌘F / ⌘K", "Focus search"), ("Tab / Shift-Tab", "Switch between search and results"),
            ("Esc", "Close the current layer; clear search before closing"), ("⌘⌥V", "Show item details"),
            ("⌘E", "Edit content in details"), ("⌘S / ⌘Return", "Save / save and paste while editing")
        ] { append("\(row.0) — \(row.1)\n", to: result) }
        append("\nFilters\n", to: result, font: .systemFont(ofSize: 15, weight: .semibold))
        append("Use the filter button for content type, source app and dates. "
            + "Changing a filter keeps your search words.\n\n", to: result)
        append("app:Safari   type:image   has:ocr\nafter:2026-01-01   before:2026-02-01\n\"exact phrase\"\n\n",
               to: result, font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        append("Set your opening shortcut in Settings → General → Shortcut. "
            + "Pause capture or ignore the next copy from More actions.\n", to: result)
        return result
    }

    private static func append(
        _ text: String, to result: NSMutableAttributedString,
        font: NSFont = .systemFont(ofSize: 13)
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        result.append(NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph
        ]))
    }
}
