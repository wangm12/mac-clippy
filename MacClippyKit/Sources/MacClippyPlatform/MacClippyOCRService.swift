import CoreGraphics
import Foundation
import ImageIO
import Vision

public enum MacClippyOCRError: Error, Equatable, LocalizedError, Sendable {
    case invalidImage
    case requestFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "The supplied data is not a valid image."
        case .requestFailed:
            return "Vision OCR request failed."
        }
    }
}

public final class MacClippyOCRService {
    public init() {}

    public func recognize(data: Data) async throws -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw MacClippyOCRError.invalidImage
        }
        return try await recognize(image: image)
    }

    public func recognize(image: CGImage) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if error != nil {
                    continuation.resume(throwing: MacClippyOCRError.requestFailed("vision_request_failed"))
                    return
                }

                let observations = (request.results as? [VNRecognizedTextObservation] ?? [])
                    .sorted { left, right in
                        let leftBox = left.boundingBox
                        let rightBox = right.boundingBox
                        if leftBox.maxY != rightBox.maxY {
                            return leftBox.maxY > rightBox.maxY
                        }
                        if leftBox.minX != rightBox.minX {
                            return leftBox.minX < rightBox.minX
                        }
                        let leftText = left.topCandidates(1).first?.string ?? ""
                        let rightText = right.topCandidates(1).first?.string ?? ""
                        return leftText < rightText
                    }
                let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            do {
                try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            } catch {
                continuation.resume(throwing: MacClippyOCRError.requestFailed("vision_request_failed"))
            }
        }
    }
}
