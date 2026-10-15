import AppKit
import Foundation
import XCTest

@testable import MacClippyPlatform

final class MacClippyPasteboardCoordinatorTests: XCTestCase {
    func testNamesShareOnlyTheirOwnCoordinator() {
        let first = NSPasteboard(name: .init("CoordinatorFirst-\(UUID())"))
        let second = NSPasteboard(name: .init("CoordinatorSecond-\(UUID())"))
        let coordinator = MacClippyPasteboardAccessCoordinator.shared(for: first)
        XCTAssertTrue(coordinator === MacClippyPasteboardAccessCoordinator.shared(for: first))
        XCTAssertFalse(coordinator === MacClippyPasteboardAccessCoordinator.shared(for: second))
    }

    func testConcurrentLookupsSerializeAndAllowNestedAccess() {
        let name = NSPasteboard.Name("CoordinatorConcurrent-\(UUID())")
        let observations = CoordinatorObservations()

        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            let board = NSPasteboard(name: name)
            let coordinator = MacClippyPasteboardAccessCoordinator.shared(for: board)
            observations.retain(coordinator)
            coordinator.withAccess {
                observations.begin()
                Thread.sleep(forTimeInterval: 0.0005)
                coordinator.withAccess { observations.recordNestedCall() }
                observations.end()
            }
        }

        XCTAssertEqual(observations.distinctCoordinatorCount, 1)
        XCTAssertEqual(observations.maximumConcurrentAccesses, 1)
        XCTAssertEqual(observations.nestedCalls, 64)
    }

    func testRegistryDoesNotKeepUnusedCoordinatorsAlive() {
        let board = NSPasteboard(name: .init("CoordinatorLifetime-\(UUID())"))
        weak var released: MacClippyPasteboardAccessCoordinator?
        autoreleasepool {
            let coordinator = MacClippyPasteboardAccessCoordinator.shared(for: board)
            released = coordinator
            XCTAssertNotNil(released)
        }
        XCTAssertNil(released)
        XCTAssertNotNil(MacClippyPasteboardAccessCoordinator.shared(for: board))
    }
}

private final class CoordinatorObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var coordinators: [MacClippyPasteboardAccessCoordinator] = []
    private var active = 0
    private(set) var maximumConcurrentAccesses = 0
    private(set) var nestedCalls = 0

    var distinctCoordinatorCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return Set(coordinators.map(ObjectIdentifier.init)).count
    }

    func retain(_ coordinator: MacClippyPasteboardAccessCoordinator) {
        lock.lock()
        defer { lock.unlock() }
        coordinators.append(coordinator)
    }

    func begin() {
        lock.lock()
        defer { lock.unlock() }
        active += 1
        maximumConcurrentAccesses = max(maximumConcurrentAccesses, active)
    }

    func recordNestedCall() {
        lock.lock()
        defer { lock.unlock() }
        nestedCalls += 1
    }

    func end() {
        lock.lock()
        defer { lock.unlock() }
        active -= 1
    }
}
