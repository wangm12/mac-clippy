import AppKit
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

import MacClippyCore
import MacClippyPlatform

struct MacClippyCompressedImage {
    let data: Data
    let width: Int
    let height: Int
    let uti: String
}

enum MacClippyThumbnailDownsampler {
    static func image(_ data: Data, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func jpegData(from image: CGImage, quality: CGFloat = 0.7) -> Data? {
        encodedData(from: image, type: .jpeg, quality: quality)
    }

    static func compressedJPEG(
        from data: Data,
        maxPixelSize: Int
    ) -> MacClippyCompressedImage? {
        guard let image = image(data, maxPixelSize: maxPixelSize),
              let jpeg = jpegData(from: image) else {
            return nil
        }
        return MacClippyCompressedImage(
            data: jpeg,
            width: image.width,
            height: image.height,
            uti: UTType.jpeg.identifier
        )
    }

    /// Downsamples image data and preserves alpha channels using HEIC (with PNG fallback).
    static func compressedImage(
        from data: Data,
        maxPixelSize: Int
    ) -> MacClippyCompressedImage? {
        guard let image = image(data, maxPixelSize: maxPixelSize) else { return nil }
        let alphaInfo = image.alphaInfo
        let hasAlpha = alphaInfo != .none && alphaInfo != .noneSkipFirst && alphaInfo != .noneSkipLast
        if hasAlpha {
            if let heic = encodedData(from: image, type: .heic, quality: 0.72) {
                return MacClippyCompressedImage(
                    data: heic,
                    width: image.width,
                    height: image.height,
                    uti: UTType.heic.identifier
                )
            }
            if let png = pngData(from: image) {
                return MacClippyCompressedImage(
                    data: png,
                    width: image.width,
                    height: image.height,
                    uti: UTType.png.identifier
                )
            }
            return nil
        }
        guard let jpeg = jpegData(from: image) else { return nil }
        return MacClippyCompressedImage(
            data: jpeg,
            width: image.width,
            height: image.height,
            uti: UTType.jpeg.identifier
        )
    }

    private static func encodedData(
        from image: CGImage,
        type: UTType,
        quality: CGFloat?
    ) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            type.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        let options: CFDictionary? = quality.map {
            [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary
        }
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    static func pngData(from image: CGImage) -> Data? {
        encodedData(from: image, type: .png, quality: nil)
    }

    static func image(fromPNG data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]
        return CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
    }
}
