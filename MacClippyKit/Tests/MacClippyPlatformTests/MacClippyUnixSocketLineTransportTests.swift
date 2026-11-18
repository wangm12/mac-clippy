import Darwin
import Foundation
import XCTest

@testable import MacClippyPlatform

final class MacClippyUnixSocketLineTransportTests: XCTestCase {
    func testReadsLargeLineAcrossDeterministicWouldBlockBoundaries() throws {
        let descriptors = try makeSocketPair()
        var serverDescriptor = descriptors[0]
        var clientDescriptor = descriptors[1]
        defer {
            if serverDescriptor >= 0 { close(serverDescriptor) }
            if clientDescriptor >= 0 { close(clientDescriptor) }
        }
        try setNonblocking(serverDescriptor)

        let text = String(repeating: "L", count: 65_536)
        let framedRequest = Data("{\"text\":\"\(text)\"}\n".utf8)
        let readResult = MacClippyUnixSocketReadResult()
        let readFinished = expectation(description: "large request read finished")
        let wouldBlockExpectations = (0..<3).map { index in
            expectation(description: "would-block boundary \(index + 1)")
        }
        let boundaryCounter = MacClippyUnixSocketBoundaryCounter()
        let descriptorForReading = serverDescriptor

        DispatchQueue.global(qos: .utility).async {
            let line = MacClippyUnixSocketLineTransport.readLine(
                from: descriptorForReading,
                maximumBytes: 2 * 1_024 * 1_024,
                timeout: 5
            ) {
                let index = boundaryCounter.incrementAndGet()
                if index <= wouldBlockExpectations.count {
                    wouldBlockExpectations[index - 1].fulfill()
                }
            }
            readResult.set(line)
            readFinished.fulfill()
        }

        let chunks = [
            Data(framedRequest.prefix(29)),
            Data(framedRequest.dropFirst(29).prefix(1_024)),
            Data(framedRequest.dropFirst(1_053))
        ]
        let sentBytes = sendChunks(chunks, after: wouldBlockExpectations, to: clientDescriptor)

        wait(for: [readFinished], timeout: 3)
        XCTAssertEqual(sentBytes, framedRequest.count)
        XCTAssertEqual(readResult.value, Data(framedRequest.dropLast()))
        XCTAssertGreaterThanOrEqual(boundaryCounter.value, 3)

        close(serverDescriptor)
        close(clientDescriptor)
        assertDescriptorClosed(serverDescriptor)
        assertDescriptorClosed(clientDescriptor)
        serverDescriptor = -1
        clientDescriptor = -1
    }

    func testAcceptsLineAtLimitAndRejectsBytesBeyondLimit() throws {
        let acceptedDescriptors = try makeSocketPair()
        var acceptedServer = acceptedDescriptors[0]
        var acceptedClient = acceptedDescriptors[1]
        defer {
            if acceptedServer >= 0 { close(acceptedServer) }
            if acceptedClient >= 0 { close(acceptedClient) }
        }
        try setNonblocking(acceptedServer)
        XCTAssertTrue(sendAll(Data("abc\n".utf8), to: acceptedClient))
        XCTAssertEqual(
            MacClippyUnixSocketLineTransport.readLine(from: acceptedServer, maximumBytes: 3, timeout: 2),
            Data("abc".utf8)
        )

        close(acceptedServer)
        close(acceptedClient)
        acceptedServer = -1
        acceptedClient = -1

        let rejectedDescriptors = try makeSocketPair()
        var rejectedServer = rejectedDescriptors[0]
        var rejectedClient = rejectedDescriptors[1]
        defer {
            if rejectedServer >= 0 { close(rejectedServer) }
            if rejectedClient >= 0 { close(rejectedClient) }
        }
        try setNonblocking(rejectedServer)
        XCTAssertTrue(sendAll(Data("abcd\n".utf8), to: rejectedClient))
        XCTAssertNil(
            MacClippyUnixSocketLineTransport.readLine(from: rejectedServer, maximumBytes: 3, timeout: 2)
        )

        close(rejectedServer)
        close(rejectedClient)
        XCTAssertEqual(fcntl(rejectedServer, F_GETFD), -1)
        XCTAssertEqual(errno, EBADF)
        XCTAssertEqual(fcntl(rejectedClient, F_GETFD), -1)
        XCTAssertEqual(errno, EBADF)
        rejectedServer = -1
        rejectedClient = -1
    }

    func testReadDeadlineReturnsForClientThatStopsSending() throws {
        let descriptors = try makeSocketPair()
        var serverDescriptor = descriptors[0]
        var clientDescriptor = descriptors[1]
        defer {
            if serverDescriptor >= 0 { close(serverDescriptor) }
            if clientDescriptor >= 0 { close(clientDescriptor) }
        }
        try setNonblocking(serverDescriptor)

        let start = DispatchTime.now().uptimeNanoseconds
        let line = MacClippyUnixSocketLineTransport.readLine(
            from: serverDescriptor,
            maximumBytes: 128,
            timeout: 0.05
        )
        let elapsedMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000

        XCTAssertNil(line)
        XCTAssertGreaterThanOrEqual(elapsedMilliseconds, 35)
        XCTAssertLessThan(elapsedMilliseconds, 500)
        close(serverDescriptor)
        close(clientDescriptor)
        XCTAssertEqual(fcntl(serverDescriptor, F_GETFD), -1)
        XCTAssertEqual(errno, EBADF)
        XCTAssertEqual(fcntl(clientDescriptor, F_GETFD), -1)
        XCTAssertEqual(errno, EBADF)
        serverDescriptor = -1
        clientDescriptor = -1
    }

    private func makeSocketPair() throws -> [Int32] {
        var descriptors: [Int32] = [-1, -1]
        let result: Int32 = descriptors.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return -1 }
            return Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, baseAddress)
        }
        guard result == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return descriptors
    }

    private func setNonblocking(_ descriptor: Int32) throws {
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    private func sendAll(_ data: Data, to descriptor: Int32) -> Bool {
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return false }
            var sentBytes = 0
            while sentBytes < bytes.count {
                let count = Darwin.send(
                    descriptor,
                    baseAddress.advanced(by: sentBytes),
                    bytes.count - sentBytes,
                    0
                )
                if count > 0 {
                    sentBytes += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }

    private func sendChunks(
        _ chunks: [Data],
        after expectations: [XCTestExpectation],
        to descriptor: Int32
    ) -> Int {
        var sentBytes = 0
        for (index, chunk) in chunks.enumerated() {
            wait(for: [expectations[index]], timeout: 3)
            XCTAssertTrue(sendAll(chunk, to: descriptor))
            sentBytes += chunk.count
        }
        return sentBytes
    }

    private func assertDescriptorClosed(_ descriptor: Int32) {
        XCTAssertEqual(fcntl(descriptor, F_GETFD), -1)
        XCTAssertEqual(errno, EBADF)
    }
}

private final class MacClippyUnixSocketReadResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Data?

    func set(_ value: Data?) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }

    var value: Data? {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }
}

private final class MacClippyUnixSocketBoundaryCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func incrementAndGet() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
