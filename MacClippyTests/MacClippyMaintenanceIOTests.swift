import CoreGraphics
import Foundation
import ImageIO
import XCTest

@testable import MacClippy
import MacClippyCore

private final class MacClippyMaintenanceResultBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Value?

    func store(_ value: Value) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }

    var value: Value? {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }
}

final class MacClippyMaintenanceIOTests: XCTestCase {
    private var tempRoot: URL!
    private var runtime: MacClippyRuntime!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacClippyMaintenanceIO-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        runtime = try MacClippyRuntime(
            paths: try MacClippyPaths(rootURL: tempRoot),
            keychain: MacClippyInMemoryKeychain()
        )
    }

    override func tearDownWithError() throws {
        MacClippyMaintenanceIOTestHooks.setAfterImageRead(nil)
        MacClippyMaintenanceIOTestHooks.setAfterBackupSnapshots(nil)
        MacClippyMaintenanceIOTestHooks.setAfterStorageSnapshot(nil)
        runtime?.closeForTesting()
        runtime = nil
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
    }

    func testStorageUsageDirectoryScanAllowsConcurrentCapture() throws {
        let sharedRuntime = runtime!
        let scanStarted = DispatchSemaphore(value: 0)
        let continueScan = DispatchSemaphore(value: 0)
        let usageResult = MacClippyMaintenanceResultBox<Result<MacClippyStorageUsage, Error>>()
        let usageFinished = DispatchSemaphore(value: 0)
        MacClippyMaintenanceIOTestHooks.setAfterStorageSnapshot {
            scanStarted.signal()
            continueScan.wait()
        }

        DispatchQueue.global(qos: .utility).async {
            usageResult.store(Result { try sharedRuntime.storageUsage() })
            usageFinished.signal()
        }
        let enteredScan = scanStarted.wait(timeout: .now() + 30) == .success
        let captureFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            _ = try? sharedRuntime.appendTestRecord(.text("capture during storage scan"))
            captureFinished.signal()
        }
        let captureProceeded = captureFinished.wait(timeout: .now() + 10) == .success
        continueScan.signal()
        XCTAssertTrue(enteredScan)
        XCTAssertTrue(captureProceeded)
        XCTAssertEqual(usageFinished.wait(timeout: .now() + 30), .success)
        XCTAssertNoThrow(try usageResult.value?.get())
    }

    func testImageCompressionAllowsConcurrentCaptureWhileImageWorkIsHeld() throws {
        let sharedRuntime = runtime!
        let image = try MacClippyMaintenanceImageFixture.appendOldImage(
            to: sharedRuntime,
            data: MacClippyMaintenanceImageFixture.makeNoisyPNG()
        )
        let imageRead = DispatchSemaphore(value: 0)
        let continueCompression = DispatchSemaphore(value: 0)
        let compressionResult = MacClippyMaintenanceResultBox<Result<MacClippyImageCompressReport, Error>>()
        let compressionFinished = DispatchSemaphore(value: 0)
        MacClippyMaintenanceIOTestHooks.setAfterImageRead {
            imageRead.signal()
            continueCompression.wait()
        }

        DispatchQueue.global(qos: .utility).async {
            compressionResult.store(Result { try sharedRuntime.compressOldImages() })
            compressionFinished.signal()
        }
        let reachedImageWork = imageRead.wait(timeout: .now() + 30) == .success
        let captureFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            _ = try? sharedRuntime.appendTestRecord(.text("capture during image work"))
            captureFinished.signal()
        }
        let captureProceeded = captureFinished.wait(timeout: .now() + 10) == .success
        continueCompression.signal()
        XCTAssertTrue(reachedImageWork)
        XCTAssertTrue(captureProceeded)
        XCTAssertEqual(compressionFinished.wait(timeout: .now() + 60), .success)
        XCTAssertNoThrow(try compressionResult.value?.get())
        XCTAssertNotNil(try sharedRuntime.clipboardStore.metas(for: [image.id]).first)
    }

    func testCancellingHeldImageCompressionDoesNotWaitForImageWork() throws {
        let sharedRuntime = runtime!
        let image = try MacClippyMaintenanceImageFixture.appendOldImage(
            to: sharedRuntime,
            data: MacClippyMaintenanceImageFixture.makeNoisyPNG()
        )
        let imageRead = DispatchSemaphore(value: 0)
        let continueCompression = DispatchSemaphore(value: 0)
        let compressionResult = MacClippyMaintenanceResultBox<Result<MacClippyImageCompressReport, Error>>()
        let compressionFinished = DispatchSemaphore(value: 0)
        MacClippyMaintenanceIOTestHooks.setAfterImageRead {
            imageRead.signal()
            continueCompression.wait()
        }

        DispatchQueue.global(qos: .utility).async {
            compressionResult.store(Result { try sharedRuntime.compressOldImages() })
            compressionFinished.signal()
        }
        let reachedHeldWork = imageRead.wait(timeout: .now() + 30) == .success
        let cancellationFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            sharedRuntime.cancelBulkMaintenanceIO()
            cancellationFinished.signal()
        }
        let cancellationReturned = cancellationFinished.wait(timeout: .now() + 10) == .success
        continueCompression.signal()

        XCTAssertTrue(reachedHeldWork)
        XCTAssertTrue(cancellationReturned)
        XCTAssertEqual(compressionFinished.wait(timeout: .now() + 30), .success)
        let result = try XCTUnwrap(compressionResult.value)
        XCTAssertThrowsError(try result.get()) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(
            try sharedRuntime.clipboardStore.body(for: image.id),
            .image(blobID: image.blobIDForTesting, width: 2_050, height: 2_050)
        )
    }

    func testImageCompressionRevalidatesChangedRevisionBeforeCommit() throws {
        let sharedRuntime = runtime!
        let image = try MacClippyMaintenanceImageFixture.appendOldImage(
            to: sharedRuntime,
            data: MacClippyMaintenanceImageFixture.makeNoisyPNG()
        )
        let imageRead = DispatchSemaphore(value: 0)
        let continueCompression = DispatchSemaphore(value: 0)
        let compressionResult = MacClippyMaintenanceResultBox<Result<MacClippyImageCompressReport, Error>>()
        let compressionFinished = DispatchSemaphore(value: 0)
        MacClippyMaintenanceIOTestHooks.setAfterImageRead {
            imageRead.signal()
            continueCompression.wait()
        }

        DispatchQueue.global(qos: .utility).async {
            compressionResult.store(Result { try sharedRuntime.compressOldImages() })
            compressionFinished.signal()
        }
        let reachedImageWork = imageRead.wait(timeout: .now() + 30) == .success
        try sharedRuntime.withStoreLock {
            _ = try sharedRuntime.clipboardStore.update(
                id: image.id,
                with: .text("new revision"),
                now: Date()
            )
        }
        continueCompression.signal()
        XCTAssertTrue(reachedImageWork)
        XCTAssertEqual(compressionFinished.wait(timeout: .now() + 60), .success)
        XCTAssertEqual(try compressionResult.value?.get().compressedCount, 0)
        XCTAssertEqual(try sharedRuntime.clipboardStore.body(for: image.id), .text("new revision"))
    }

    func testImageCompressionRechecksPinProtectionBeforeCommit() throws {
        let sharedRuntime = runtime!
        let image = try MacClippyMaintenanceImageFixture.appendOldImage(
            to: sharedRuntime,
            data: MacClippyMaintenanceImageFixture.makeNoisyPNG()
        )
        let board = try sharedRuntime.createPinboard(name: "Protected during compression", color: nil)
        let imageRead = DispatchSemaphore(value: 0)
        let continueCompression = DispatchSemaphore(value: 0)
        let compressionResult = MacClippyMaintenanceResultBox<Result<MacClippyImageCompressReport, Error>>()
        let compressionFinished = DispatchSemaphore(value: 0)
        MacClippyMaintenanceIOTestHooks.setAfterImageRead {
            imageRead.signal()
            continueCompression.wait()
        }

        DispatchQueue.global(qos: .utility).async {
            compressionResult.store(Result { try sharedRuntime.compressOldImages() })
            compressionFinished.signal()
        }
        let reachedImageWork = imageRead.wait(timeout: .now() + 30) == .success
        try sharedRuntime.pin(recordID: image.id, to: board.id)
        continueCompression.signal()
        XCTAssertTrue(reachedImageWork)
        XCTAssertEqual(compressionFinished.wait(timeout: .now() + 60), .success)
        XCTAssertEqual(try compressionResult.value?.get().compressedCount, 0)
        XCTAssertEqual(
            try sharedRuntime.clipboardStore.body(for: image.id),
            .image(blobID: image.blobIDForTesting, width: 2_050, height: 2_050)
        )
    }

    func testBackupKeepsSnapshotRecordAndBlobTogetherDuringDeletion() throws {
        let sharedRuntime = runtime!
        let image = try MacClippyMaintenanceImageFixture.appendOldImage(
            to: sharedRuntime,
            data: MacClippyMaintenanceImageFixture.onePixelPNG,
            width: 1,
            height: 1
        )
        let backupURL = tempRoot.appendingPathComponent("maintenance-snapshot", isDirectory: true)
        let snapshotsReady = DispatchSemaphore(value: 0)
        let continueBackup = DispatchSemaphore(value: 0)
        let backupResult = MacClippyMaintenanceResultBox<Result<MacClippyBackupManifest, Error>>()
        let backupFinished = DispatchSemaphore(value: 0)
        MacClippyMaintenanceIOTestHooks.setAfterBackupSnapshots {
            snapshotsReady.signal()
            continueBackup.wait()
        }

        DispatchQueue.global(qos: .utility).async {
            backupResult.store(Result { try sharedRuntime.createBackup(at: backupURL) })
            backupFinished.signal()
        }
        let capturedSnapshots = snapshotsReady.wait(timeout: .now() + 30) == .success
        try sharedRuntime.delete(id: image.id)
        _ = try sharedRuntime.appendTestRecord(.text("record after backup snapshot"))
        continueBackup.signal()

        XCTAssertTrue(capturedSnapshots)
        XCTAssertEqual(backupFinished.wait(timeout: .now() + 60), .success)
        let manifest = try XCTUnwrap(backupResult.value).get()
        let validation = try MacClippyBackup.validate(
            at: backupURL,
            keySource: sharedRuntime.clipboardStore.backupKeySource
        )
        XCTAssertTrue(validation.keyCompatible)
        XCTAssertEqual(validation.databaseRowCounts["clipboard"], 1)
        XCTAssertTrue(manifest.files.contains { $0.relativePath == "blobs/\(image.blobIDForTesting).bin" })
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: backupURL.appendingPathComponent("blobs/\(image.blobIDForTesting).bin").path
            )
        )
    }

}

private enum MacClippyMaintenanceImageFixture {
    static func appendOldImage(
        to runtime: MacClippyRuntime,
        data: Data,
        width: Int = 2_050,
        height: Int = 2_050
    ) throws -> (id: RecordID, blobIDForTesting: String) {
        let blobID = try runtime.blobStore.write(data)
        let meta = try runtime.withStoreLock {
            try runtime.clipboardStore.append(
                .image(blobID: blobID, width: width, height: height),
                now: Date(timeIntervalSinceNow: -20 * 24 * 60 * 60)
            )
        }
        return (meta.id, blobID)
    }

    static func makeNoisyPNG() throws -> Data {
        let width = 2_050
        let height = 2_050
        var pixels = Data(count: width * height * 4)
        pixels.withUnsafeMutableBytes { rawBuffer in
            guard let bytes = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            var state: UInt32 = 0x1357_9BDF
            for offset in stride(from: 0, to: width * height * 4, by: 4) {
                state ^= state << 13
                state ^= state >> 17
                state ^= state << 5
                bytes[offset] = UInt8(truncatingIfNeeded: state)
                bytes[offset + 1] = UInt8(truncatingIfNeeded: state >> 8)
                bytes[offset + 2] = UInt8(truncatingIfNeeded: state >> 16)
                bytes[offset + 3] = 255
            }
        }
        let image = pixels.withUnsafeMutableBytes { rawBuffer -> CGImage? in
            guard let context = CGContext(
                data: rawBuffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else {
                return nil
            }
            return context.makeImage()
        }
        let cgImage = try XCTUnwrap(image)
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, "public.png" as CFString, 1, nil) else {
            throw MacClippyMaintenanceIOTestError.imageEncodeFailed
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw MacClippyMaintenanceIOTestError.imageEncodeFailed
        }
        return encoded as Data
    }

    static let onePixelPNG: Data = {
        Data([
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
            0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
            0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x62, 0x00, 0x01, 0x00, 0x00,
            0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
            0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82
        ])
    }()
}

private enum MacClippyMaintenanceIOTestError: Error {
    case imageEncodeFailed
}
