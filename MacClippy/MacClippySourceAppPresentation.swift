import AppKit
import Foundation
import SwiftUI

import MacClippyCore

struct MacClippySourceRGB: Equatable {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
}

enum MacClippySourceAccent {
    static let neutralRGB = MacClippySourceRGB(red: 0.48, green: 0.50, blue: 0.54)

    static func representativeRGB(from pixels: [MacClippySourceRGB]) -> MacClippySourceRGB {
        guard !pixels.isEmpty else { return neutralRGB }

        let colorfulPixels = pixels.filter { pixel in
            let maximum = max(pixel.red, pixel.green, pixel.blue)
            let minimum = min(pixel.red, pixel.green, pixel.blue)
            return maximum - minimum >= 0.10 && maximum >= 0.18
        }
        guard !colorfulPixels.isEmpty else { return neutralRGB }

        var weightedRGB = MacClippySourceRGB(red: 0, green: 0, blue: 0)
        var totalWeight: CGFloat = 0
        for pixel in colorfulPixels {
            let maximum = max(pixel.red, pixel.green, pixel.blue)
            let minimum = min(pixel.red, pixel.green, pixel.blue)
            let weight = (maximum - minimum) * maximum
            weightedRGB = MacClippySourceRGB(
                red: weightedRGB.red + pixel.red * weight,
                green: weightedRGB.green + pixel.green * weight,
                blue: weightedRGB.blue + pixel.blue * weight
            )
            totalWeight += weight
        }

        let average = MacClippySourceRGB(
            red: weightedRGB.red / max(totalWeight, 0.001),
            green: weightedRGB.green / max(totalWeight, 0.001),
            blue: weightedRGB.blue / max(totalWeight, 0.001)
        )
        let fallback = colorfulPixels.max { left, right in
            let leftWeight = (max(left.red, left.green, left.blue) - min(left.red, left.green, left.blue)) * max(left.red, left.green, left.blue)
            let rightWeight = (max(right.red, right.green, right.blue) - min(right.red, right.green, right.blue)) * max(right.red, right.green, right.blue)
            return leftWeight < rightWeight
        } ?? average
        let averageChroma = max(average.red, average.green, average.blue) - min(average.red, average.green, average.blue)
        let source = averageChroma >= 0.08 ? average : fallback
        let red = source.red
        let green = source.green
        let blue = source.blue
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let chroma = maximum - minimum
        let saturation = min(max(chroma / max(maximum, 0.001), 0.52), 0.82)
        let brightness = min(max(maximum * 1.08, 0.58), 0.86)
        let hue: CGFloat

        if chroma == 0 {
            hue = 0.58
        } else if maximum == red {
            hue = ((green - blue) / chroma).truncatingRemainder(dividingBy: 6) / 6
        } else if maximum == green {
            hue = ((blue - red) / chroma + 2) / 6
        } else {
            hue = ((red - green) / chroma + 4) / 6
        }

        return rgbFromHSV(hue: hue < 0 ? hue + 1 : hue, saturation: saturation, brightness: brightness)
    }

    private static func rgbFromHSV(hue: CGFloat, saturation: CGFloat, brightness: CGFloat) -> MacClippySourceRGB {
        let scaled = hue * 6
        let sector = Int(floor(scaled))
        let fraction = scaled - CGFloat(sector)
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - saturation * fraction)
        let t = brightness * (1 - saturation * (1 - fraction))

        switch sector % 6 {
        case 0: return MacClippySourceRGB(red: brightness, green: t, blue: p)
        case 1: return MacClippySourceRGB(red: q, green: brightness, blue: p)
        case 2: return MacClippySourceRGB(red: p, green: brightness, blue: t)
        case 3: return MacClippySourceRGB(red: p, green: q, blue: brightness)
        case 4: return MacClippySourceRGB(red: t, green: p, blue: brightness)
        default: return MacClippySourceRGB(red: brightness, green: p, blue: q)
        }
    }
}

struct MacClippySourceAppPresentation {
    let displayName: String
    let icon: NSImage?
    let accent: NSColor

    var accentRGB: MacClippySourceRGB {
        guard let converted = accent.usingColorSpace(.deviceRGB) else {
            return MacClippySourceAccent.neutralRGB
        }
        return MacClippySourceRGB(
            red: converted.redComponent,
            green: converted.greenComponent,
            blue: converted.blueComponent
        )
    }

    static let unknown = MacClippySourceAppPresentation(
        displayName: "Unknown source",
        icon: nil,
        accent: NSColor(deviceRed: MacClippySourceAccent.neutralRGB.red, green: MacClippySourceAccent.neutralRGB.green, blue: MacClippySourceAccent.neutralRGB.blue, alpha: 1)
    )
}

enum MacClippySourceAppResolver {
    private final class CacheEntry: NSObject {
        let presentation: MacClippySourceAppPresentation

        init(_ presentation: MacClippySourceAppPresentation) {
            self.presentation = presentation
        }
    }

    private static let cache = Cache()

    private static let resolutionQueue = DispatchQueue(
        label: "com.macallyouneed.macclippy.source-app-resolution",
        qos: .utility,
        attributes: .concurrent
    )
    private static let inFlightLock = NSLock()
    // Access is serialized by inFlightLock; `nonisolated(unsafe)` documents
    // that this is an intentional lock-protected boundary for the utility
    // resolution queue rather than an actor-owned UI state value.
    nonisolated(unsafe) private static var inFlight = Set<String>()
    #if DEBUG
    nonisolated(unsafe) static var testDisplayNames: [String: String] = [:]
    #endif

    static func presentation(for bundleIdentifier: String?) -> MacClippySourceAppPresentation {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else {
            return MacClippySourceAppPresentation.unknown
        }

        let key = bundleIdentifier as NSString
        if let cached = cache.object(for: key) {
            return cached.presentation
        }

        scheduleResolution(for: bundleIdentifier)
        return .unknown
    }

    /// Resolves the localized app name on the calling thread and caches it.
    /// Search must not use `presentation(for:)`, which returns
    /// "Unknown source" until the async icon path finishes.
    static func displayName(for bundleIdentifier: String?) -> String? {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return nil }
        #if DEBUG
        if let override = testDisplayNames[bundleIdentifier] {
            return override
        }
        #endif
        let key = bundleIdentifier as NSString
        if let cached = cache.object(for: key) {
            return usableDisplayName(cached.presentation.displayName)
        }
        let presentation = resolve(bundleIdentifier: bundleIdentifier)
        cache.setObject(CacheEntry(presentation), forKey: bundleIdentifier)
        return usableDisplayName(presentation.displayName)
    }

    static func searchHaystacks(for bundleIdentifier: String?) -> [String] {
        MacClippySourceAppSearch.segments(
            bundleID: bundleIdentifier,
            displayName: displayName(for: bundleIdentifier)
        )
    }

    private static func usableDisplayName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.caseInsensitiveCompare(MacClippySourceAppSearch.unknownDisplayName) != .orderedSame else {
            return nil
        }
        return trimmed
    }

    private static func scheduleResolution(for bundleIdentifier: String) {
        inFlightLock.lock()
        guard inFlight.insert(bundleIdentifier).inserted else {
            inFlightLock.unlock()
            return
        }
        inFlightLock.unlock()

        resolutionQueue.async {
            let presentation = resolve(bundleIdentifier: bundleIdentifier)
            cache.setObject(CacheEntry(presentation), forKey: bundleIdentifier)
            inFlightLock.lock()
            inFlight.remove(bundleIdentifier)
            inFlightLock.unlock()
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .macClippySourceAppPresentationDidResolve,
                    object: bundleIdentifier
                )
            }
        }
    }

    private static func resolve(bundleIdentifier: String) -> MacClippySourceAppPresentation {
        guard let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return MacClippySourceAppPresentation(
                displayName: bundleIdentifier,
                icon: nil,
                accent: MacClippySourceAppPresentation.unknown.accent
            )
        }

        let icon = NSWorkspace.shared.icon(forFile: applicationURL.path)
        let accentRGB = MacClippySourceAccent.representativeRGB(from: pixels(in: icon))
        let displayIcon = MacClippySourceAppIcon.prepared(
            icon,
            pointSize: MacClippyDockCardMetrics.sourceBadgeSize
        )
        let displayName = (Bundle(url: applicationURL)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle(url: applicationURL)?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? applicationURL.deletingPathExtension().lastPathComponent
            .nonEmptyOr(bundleIdentifier)

        return MacClippySourceAppPresentation(
            displayName: displayName,
            icon: displayIcon,
            accent: NSColor(deviceRed: accentRGB.red, green: accentRGB.green, blue: accentRGB.blue, alpha: 1)
        )
    }

    private static func pixels(in image: NSImage) -> [MacClippySourceRGB] {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return []
        }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0 else {
            return []
        }

        let sampleStride = max(1, max(bitmap.pixelsWide, bitmap.pixelsHigh) / 24)
        var pixels: [MacClippySourceRGB] = []
        pixels.reserveCapacity(24 * 24)
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: sampleStride) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: sampleStride) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      color.alphaComponent > 0.15 else { continue }
                pixels.append(MacClippySourceRGB(
                    red: color.redComponent,
                    green: color.greenComponent,
                    blue: color.blueComponent
                ))
            }
        }
        return pixels
    }

    private final class Cache: @unchecked Sendable {
        private let storage: NSCache<NSString, CacheEntry> = {
            let storage = NSCache<NSString, CacheEntry>()
            storage.countLimit = 128
            return storage
        }()

        func object(for key: NSString) -> CacheEntry? {
            storage.object(forKey: key)
        }

        func setObject(_ entry: CacheEntry, forKey key: String) {
            storage.setObject(entry, forKey: key as NSString)
        }
    }
}

enum MacClippySourceAppIcon {
    // Tahoe app icons have Default / Dark / Clear / Tinted variants.
    // The dock panel is darkAqua, so a raw NSWorkspace icon flattens to
    // the dark glass tile. Draw the Default (aqua) representation at the
    // badge point size so Safari/Chrome stay recognizable corner badges.
    static func prepared(_ icon: NSImage, pointSize: CGFloat) -> NSImage {
        let canvas = NSSize(width: pointSize, height: pointSize)
        let source = (icon.copy() as? NSImage) ?? icon
        source.size = canvas
        return NSImage(size: canvas, flipped: false) { rect in
            NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
                source.draw(in: rect)
            }
            return true
        }
    }
}

extension Notification.Name {
    static let macClippySourceAppPresentationDidResolve = Notification.Name(
        "MacClippy.sourceAppPresentationDidResolve"
    )
}

private extension String {
    func nonEmptyOr(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}
