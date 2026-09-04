import AppKit
import CoreGraphics
import MacClippyPlatform
import SwiftUI

@MainActor
protocol MacClippyPreviewTextSelectionHost: AnyObject {
    var hasSelectedText: Bool { get }
    var selectedText: String? { get }
    func copySelectedText()
}

struct MacClippyDockPreviewImageSelection: NSViewRepresentable {
    let image: CGImage?
    let ocrResult: MacClippyOCRResult?
    var highlightTerms: [String] = []
    let onSelectionChanged: ((String?) -> Void)?
    let onCopySelection: ((String) -> Void)?

    func makeNSView(context: Context) -> MacClippyOCRSelectionView {
        let view = MacClippyOCRSelectionView()
        view.onSelectionChanged = onSelectionChanged
        view.onCopySelection = onCopySelection
        view.update(image: image, result: ocrResult, highlightTerms: highlightTerms)
        return view
    }

    func updateNSView(_ nsView: MacClippyOCRSelectionView, context: Context) {
        nsView.onSelectionChanged = onSelectionChanged
        nsView.onCopySelection = onCopySelection
        nsView.update(image: image, result: ocrResult, highlightTerms: highlightTerms)
    }
}

enum MacClippyPreviewImageGeometry {
    static func aspectFitRect(imageSize: CGSize, in bounds: NSRect) -> NSRect {
        guard imageSize.width > 0, imageSize.height > 0,
              bounds.width > 0, bounds.height > 0 else {
            return .zero
        }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return NSRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    static func map(
        _ normalized: MacClippyOCRNormalizedRect,
        into imageRect: NSRect
    ) -> NSRect {
        let minX = imageRect.minX + CGFloat(normalized.minX) * imageRect.width
        let maxY = imageRect.maxY - CGFloat(normalized.minY) * imageRect.height
        let width = CGFloat(normalized.width) * imageRect.width
        let height = CGFloat(normalized.height) * imageRect.height
        return NSRect(x: minX, y: maxY - height, width: width, height: height)
    }
}

struct MacClippyOCRSelectionLayout {
    let imageRect: NSRect
    let lineRects: [NSRect]
    let hitLineRects: [NSRect]
    let characterRects: [[NSRect?]]
}

struct MacClippyOCRTextPosition: Equatable {
    let line: Int
    let offset: Int
}

enum MacClippyOCRSelectionPolicy {
    static func selectedText(
        in result: MacClippyOCRResult,
        anchor: MacClippyOCRTextPosition,
        active: MacClippyOCRTextPosition
    ) -> String? {
        guard anchor != active,
              result.lines.indices.contains(anchor.line),
              result.lines.indices.contains(active.line) else { return nil }

        let (start, end): (MacClippyOCRTextPosition, MacClippyOCRTextPosition)
        if anchor.line < active.line || (anchor.line == active.line && anchor.offset <= active.offset) {
            (start, end) = (anchor, active)
        } else {
            (start, end) = (active, anchor)
        }

        var selectedLines: [String] = []
        for lineIndex in start.line...end.line {
            let characters = result.lines[lineIndex].characters.map(\.text)
            let lowerBound = min(max(lineIndex == start.line ? start.offset : 0, 0), characters.count)
            let upperBound = min(
                max(lineIndex == end.line ? end.offset : characters.count, 0),
                characters.count
            )
            guard lowerBound < upperBound else { continue }
            selectedLines.append(characters[lowerBound..<upperBound].joined())
        }

        let value = selectedLines.joined(separator: "\n")
        return value.isEmpty ? nil : value
    }
}

@MainActor
final class MacClippyOCRSelectionView: NSView, MacClippyPreviewTextSelectionHost {
    struct Endpoint: Equatable {
        let line: Int
        let offset: Int
    }

    struct Selection: Equatable {
        let anchor: Endpoint
        var active: Endpoint

        var ordered: (Endpoint, Endpoint) {
            if anchor.line < active.line || (anchor.line == active.line && anchor.offset <= active.offset) {
                return (anchor, active)
            }
            return (active, anchor)
        }
    }

    private var image: CGImage?
    private var ocrResult: MacClippyOCRResult?
    private var highlightTerms: [String] = []
    private var selection: Selection?
    private var renderedImage: NSImage?
    var selectionLayoutCache: MacClippyOCRSelectionLayout?

    var onSelectionChanged: ((String?) -> Void)?
    var onCopySelection: ((String) -> Void)?

    var hasSelectedText: Bool {
        selectedText != nil
    }

    var selectedText: String? {
        guard let selection,
              let ocrResult else { return nil }
        let (start, end) = selection.ordered
        return MacClippyOCRSelectionPolicy.selectedText(
            in: ocrResult,
            anchor: MacClippyOCRTextPosition(line: start.line, offset: start.offset),
            active: MacClippyOCRTextPosition(line: end.line, offset: end.offset)
        )
    }

    override var isFlipped: Bool { true }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              MacClippyDockKeyRouterPolicy.isCommandCopy(
                  keyCode: event.keyCode,
                  modifiers: event.modifierFlags
              ),
              hasSelectedText else {
            return false
        }
        copySelectedText()
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Clipboard image preview")
        setAccessibilityHelp("Drag across recognized text to select it, then press Command-C to copy.")
        updateAccessibilityValue()
    }

    func update(image: CGImage?, result: MacClippyOCRResult?, highlightTerms: [String] = []) {
        let imageChanged = self.image?.width != image?.width || self.image?.height != image?.height
        let resultChanged = self.ocrResult != result
        let termsChanged = self.highlightTerms != highlightTerms
        self.image = image
        self.ocrResult = result
        self.highlightTerms = highlightTerms
        if imageChanged {
            renderedImage = image.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
        }
        if imageChanged || resultChanged {
            selectionLayoutCache = nil
            clearSelection()
        }
        if imageChanged || resultChanged || termsChanged {
            needsDisplay = true
        }
    }

    func copySelectedText() {
        guard let selectedText else { return }
        onCopySelection?(selectedText)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.clear.setFill()
        dirtyRect.fill()
        guard let image else { return }
        let imageRect = MacClippyPreviewImageGeometry.aspectFitRect(
            imageSize: CGSize(width: image.width, height: image.height),
            in: bounds
        )
        guard let renderedImage else { return }
        renderedImage.draw(
            in: imageRect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
        guard let ocrResult else { return }
        let layout = selectionLayout(for: ocrResult, imageRect: imageRect)
        drawSearchHits(result: ocrResult, imageRect: imageRect, terms: highlightTerms)
        if let selection {
            drawSelection(
                selection,
                result: ocrResult,
                layout: layout
            )
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let point = eventLocation(event),
              let endpoint = endpoint(at: point) else {
            clearSelection()
            return
        }
        window?.makeFirstResponder(self)
        selection = Selection(anchor: endpoint, active: endpoint)
        publishSelection()
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard var selection,
              let point = eventLocation(event),
              let endpoint = endpoint(at: point) else { return }
        selection.active = endpoint
        self.selection = selection
        publishSelection()
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard selection != nil else { return }
        if let point = eventLocation(event), let endpoint = endpoint(at: point) {
            selection?.active = endpoint
            publishSelection()
            needsDisplay = true
        }
    }

    private func eventLocation(_ event: NSEvent) -> NSPoint? {
        guard window != nil else { return nil }
        return convert(event.locationInWindow, from: nil)
            .clamped(to: bounds)
    }

    private func endpoint(at point: NSPoint) -> Endpoint? {
        guard let image, let ocrResult else { return nil }
        let imageRect = MacClippyPreviewImageGeometry.aspectFitRect(
            imageSize: CGSize(width: image.width, height: image.height),
            in: bounds
        )
        guard imageRect.contains(point) else { return nil }

        guard let lineIndex = nearestLineIndex(at: point, imageRect: imageRect, in: ocrResult) else {
            return nil
        }
        return endpoint(
            at: point,
            lineIndex: lineIndex,
            imageRect: imageRect,
            in: ocrResult
        )
    }

    private func nearestLineIndex(
        at point: NSPoint,
        imageRect: NSRect,
        in result: MacClippyOCRResult
    ) -> Int? {
        let layout = selectionLayout(for: result, imageRect: imageRect)
        var bestLine: (index: Int, distance: CGFloat)?
        for (index, lineRect) in layout.hitLineRects.enumerated() {
            guard lineRect.contains(point) else { continue }
            let distance = abs(lineRect.midY - point.y)
            if let current = bestLine {
                if distance < current.distance {
                    bestLine = (index, distance)
                }
            } else {
                bestLine = (index, distance)
            }
        }
        return bestLine?.index
    }

    private func endpoint(
        at point: NSPoint,
        lineIndex: Int,
        imageRect: NSRect,
        in result: MacClippyOCRResult
    ) -> Endpoint {
        let line = result.lines[lineIndex]
        let characters = line.characters
        guard !characters.isEmpty else { return Endpoint(line: lineIndex, offset: 0) }

        let layout = selectionLayout(for: result, imageRect: imageRect)
        let lineRect = layout.lineRects[lineIndex]

        if !line.hasCompleteCharacterGeometry {
            return Endpoint(line: lineIndex, offset: point.x < lineRect.midX ? 0 : characters.count)
        }

        for (index, characterRect) in layout.characterRects[lineIndex].enumerated() {
            guard let characterRect else { continue }
            if point.x <= characterRect.midX {
                return Endpoint(line: lineIndex, offset: index)
            }
        }
        return Endpoint(line: lineIndex, offset: characters.count)
    }

    private func clearSelection() {
        selection = nil
        publishSelection()
        needsDisplay = true
    }

    private func publishSelection() {
        updateAccessibilityValue()
        onSelectionChanged?(selectedText)
    }

    private func updateAccessibilityValue() {
        setAccessibilityValue(selectedText == nil ? "No text selected" : "Text selected")
    }

    func selectionLayout(
        for result: MacClippyOCRResult,
        imageRect: NSRect
    ) -> MacClippyOCRSelectionLayout {
        if let selectionLayoutCache,
           selectionLayoutCache.imageRect == imageRect {
            return selectionLayoutCache
        }

        let lineRects = result.lines.map {
            MacClippyPreviewImageGeometry.map($0.boundingBox, into: imageRect)
        }
        let hitLineRects = lineRects.map { $0.insetBy(dx: -6, dy: -6) }
        let characterRects = result.lines.map { line in
            line.characters.map { character in
                character.boundingBox.map {
                    MacClippyPreviewImageGeometry.map($0, into: imageRect)
                }
            }
        }
        let layout = MacClippyOCRSelectionLayout(
            imageRect: imageRect,
            lineRects: lineRects,
            hitLineRects: hitLineRects,
            characterRects: characterRects
        )
        selectionLayoutCache = layout
        return layout
    }
}

private extension NSPoint {
    func clamped(to rect: NSRect) -> NSPoint {
        NSPoint(
            x: min(max(x, rect.minX), rect.maxX),
            y: min(max(y, rect.minY), rect.maxY)
        )
    }
}
