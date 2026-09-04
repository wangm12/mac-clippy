import Foundation

/// When Vision OCR may start, and the pixel/byte caps it must keep.
/// The 2 / 8 / 64MB queue budget is unchanged; this only defers work until
/// the session is idle and not in Low Power Mode, and clamps huge screenshots
/// before recognition.
public enum MacClippyOCRSchedulePolicy {
    public static let maxConcurrentRecognizers = 2
    public static let maxPendingJobs = 8
    public static let maxPendingBytes = 64 * 1024 * 1024
    public static let idleThreshold: TimeInterval = 2
    public static let recognitionMaxPixelSize = 2_048

    public static func shouldStartRecognition(
        secondsSinceLastInput: TimeInterval,
        isLowPowerMode: Bool
    ) -> Bool {
        !isLowPowerMode && secondsSinceLastInput >= idleThreshold
    }

    public static func recognitionPixelLimit(sourceMaxPixelSize: Int) -> Int {
        min(max(1, sourceMaxPixelSize), recognitionMaxPixelSize)
    }
}
