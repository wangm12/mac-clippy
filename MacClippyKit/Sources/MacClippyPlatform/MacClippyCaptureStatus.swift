import Foundation

public struct MacClippyCaptureStatus: Equatable, Sendable {
    public let isPaused: Bool
    public let remainingIgnoredCopies: Int

    public init(isPaused: Bool = false, remainingIgnoredCopies: Int = 0) {
        self.isPaused = isPaused
        self.remainingIgnoredCopies = remainingIgnoredCopies
    }
}

extension Notification.Name {
    public static let macClippyCaptureStatusDidChange = Notification.Name("MacClippyCaptureStatusDidChange")
}

extension MacClippyPasteboardObserver {
    func publishCaptureStatus() {
        let status = MacClippyCaptureStatus(
            isPaused: capturePaused, remainingIgnoredCopies: ignoreNextCopyCount)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            NotificationCenter.default.post(
                name: .macClippyCaptureStatusDidChange, object: self, userInfo: ["status": status]
            )
        }
    }
}

extension MacClippyPasteboardObserver {
    public func readCaptureStatus(_ completion: @escaping @Sendable (MacClippyCaptureStatus) -> Void) {
        enqueueOnLifecycleQueue { [weak self] in
            guard let self else { return }
            completion(.init(isPaused: self.capturePaused, remainingIgnoredCopies: self.ignoreNextCopyCount))
        }
    }

    public func cancelIgnoredCopies() {
        enqueueOnLifecycleQueue { [weak self] in
            self?.ignoreNextCopyCount = 0
            self?.publishCaptureStatus()
        }
    }
}
