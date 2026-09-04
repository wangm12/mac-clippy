import AppKit

/// Menu-bar extras must be template glyphs, not the Dock app icon.
/// Apple tints the alpha mask for light and dark menu bars.
public enum MacClippyStatusItemIconPolicy {
    public static let pointSize = NSSize(width: 18, height: 18)
    public static let imageName = "MenuBarIcon"
    public static let fallbackSystemSymbolName = "scissors"

    public static func makeImage(
        namedImage: NSImage? = NSImage(named: imageName),
        fallbackSystemSymbolName: String = fallbackSystemSymbolName
    ) -> NSImage? {
        let resolved = namedImage
            ?? NSImage(
                systemSymbolName: fallbackSystemSymbolName,
                accessibilityDescription: "Mac Clippy"
            )
        return prepared(resolved)
    }

    public static func prepared(_ image: NSImage?) -> NSImage? {
        guard let copy = image?.copy() as? NSImage else { return nil }
        copy.isTemplate = true
        copy.size = pointSize
        return copy
    }
}
