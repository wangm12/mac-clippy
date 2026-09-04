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

private final class MacClippyOCRContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<MacClippyOCRResult, Error>?
    private var request: VNRecognizeTextRequest?
    private var completed = false

    func install(_ request: VNRecognizeTextRequest) {
        lock.lock()
        self.request = request
        let shouldCancel = completed
        lock.unlock()
        if shouldCancel { request.cancel() }
    }

    func install(_ continuation: CheckedContinuation<MacClippyOCRResult, Error>) {
        lock.lock()
        if completed {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resume(_ result: Result<MacClippyOCRResult, Error>) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        guard let continuation else { return }
        switch result {
        case let .success(value): continuation.resume(returning: value)
        case let .failure(error): continuation.resume(throwing: error)
        }
    }

    func cancel() {
        resume(.failure(CancellationError()))
    }

    func cancelRequest() {
        lock.lock()
        let request = self.request
        lock.unlock()
        request?.cancel()
    }
}

public final class MacClippyOCRService {
    // OCR accuracy does not improve enough from decoding a clipboard image at
    // poster-sized resolution to justify the peak memory cost. Keep the full
    // source data for paste/preview; only the Vision input is bounded.
    public static let maxImagePixelSize = MacClippyOCRSchedulePolicy.recognitionMaxPixelSize

    public init() {}

    public func recognize(data: Data) async throws -> String {
        try await recognizeLayout(data: data).fullText
    }

    public func recognizeLayout(data: Data) async throws -> MacClippyOCRResult {
        guard let image = Self.imageForRecognition(data: data) else {
            throw MacClippyOCRError.invalidImage
        }
        return try await recognizeLayout(image: image)
    }

    private static func imageForRecognition(data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: MacClippyOCRSchedulePolicy.recognitionPixelLimit(
                sourceMaxPixelSize: maxImagePixelSize
            ),
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        // Never fall back to decoding the original image. A compressed image
        // can have a small Data footprint but an enormous pixel footprint;
        // OCR must fail closed when ImageIO cannot produce a bounded thumbnail
        // rather than turning an enrichment task into an OOM risk.
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    public func recognize(image: CGImage) async throws -> String {
        try await recognizeLayout(image: image).fullText
    }

    public func recognizeLayout(image: CGImage) async throws -> MacClippyOCRResult {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .utility) {
            try await Self.recognizeLayoutOnUtilityExecutor(image: image)
        }
        return try await withTaskCancellationHandler(operation: {
            try await worker.value
        }, onCancel: {
            worker.cancel()
        })
    }

    private static func recognizeLayoutOnUtilityExecutor(image: CGImage) async throws -> MacClippyOCRResult {
        try Task.checkCancellation()
        let continuationBox = MacClippyOCRContinuationBox()
        let request = VNRecognizeTextRequest { request, error in
            if error != nil {
                continuationBox.resume(
                    .failure(Task.isCancelled ? CancellationError() : MacClippyOCRError.requestFailed("vision_request_failed"))
                )
                return
            }

            let observations = request.results as? [VNRecognizedTextObservation] ?? []
            let lines = Self.textLines(from: observations)
            continuationBox.resume(.success(MacClippyOCRResult(lines: lines)))
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if #available(macOS 13.0, *) {
            // Screenshots often mix English code/UI text with Chinese labels.
            // Automatic language detection lets Vision use the languages
            // supported by the active recognition revision.
            request.automaticallyDetectsLanguage = true
        }
        continuationBox.install(request)

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                continuationBox.install(continuation)
                do {
                    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                } catch {
                    continuationBox.resume(
                        .failure(Task.isCancelled ? CancellationError() : MacClippyOCRError.requestFailed("vision_request_failed"))
                    )
                }
            }
        }, onCancel: {
            continuationBox.cancelRequest()
            continuationBox.cancel()
        })
    }

    private static func textLines(
        from observations: [VNRecognizedTextObservation]
    ) -> [MacClippyOCRTextLine] {
        observations
            .sorted(by: sortObservations)
            .compactMap(textLine(from:))
    }

    private static func sortObservations(
        _ left: VNRecognizedTextObservation,
        _ right: VNRecognizedTextObservation
    ) -> Bool {
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

    private static func textLine(
        from observation: VNRecognizedTextObservation
    ) -> MacClippyOCRTextLine? {
        guard let recognizedText = observation.topCandidates(1).first else { return nil }
        let text = recognizedText.string
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return MacClippyOCRTextLine(
            text: text,
            boundingBox: normalizedRect(observation.boundingBox),
            characters: characters(in: text, recognizedText: recognizedText)
        )
    }

    private static func characters(
        in text: String,
        recognizedText: VNRecognizedText
    ) -> [MacClippyOCRCharacter] {
        text.indices.map { startIndex in
            let endIndex = text.index(after: startIndex)
            let characterText = String(text[startIndex..<endIndex])
            let box = try? recognizedText.boundingBox(for: startIndex..<endIndex)
            return MacClippyOCRCharacter(
                text: characterText,
                boundingBox: box.map { normalizedRect($0.boundingBox) }
            )
        }
    }

    private static func normalizedRect(_ rect: CGRect) -> MacClippyOCRNormalizedRect {
        MacClippyOCRNormalizedRect(
            minX: Double(rect.minX),
            minY: Double(rect.minY),
            width: Double(rect.width),
            height: Double(rect.height)
        )
    }
}
