import Foundation

@testable import MacClippyPlatform

// Models a lazy provider: read() returns the current change, while reread(...)
// can return materialized data on a later poll.
final class SteppingTestPasteboardReader: PasteboardReading {
    var change: PasteboardChange
    var rereadResult: PasteboardChange?
    var forcedChangeCounts: [Int] = []
    private(set) var readCount = 0
    private(set) var rereadCount = 0

    init(initial: PasteboardChange) {
        self.change = initial
    }

    func currentChangeCount() -> Int {
        if !forcedChangeCounts.isEmpty {
            return forcedChangeCounts.removeFirst()
        }
        return change.changeCount
    }

    func read() -> PasteboardChange {
        readCount += 1
        return change
    }

    func reread(change: PasteboardChange, unavailableTypes: [(itemIndex: Int, uti: String)]) -> PasteboardChange {
        rereadCount += 1
        return rereadResult ?? change
    }
}
