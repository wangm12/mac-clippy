import Darwin
import Foundation
import XCTest

@testable import MacClippyPlatform

final class MacClippyUnixSocketWriteTransportTests: XCTestCase {
    func testWriteLineSurvivesPeerCloseAfterPartialWrite() throws {
        let descriptors = try makeSocketPair()
        var serverDescriptor = descriptors[0]
        var clientDescriptor = descriptors[1]
        defer {
            if serverDescriptor >= 0 { close(serverDescriptor) }
            if clientDescriptor >= 0 { close(clientDescriptor) }
        }
        try setNonblocking(serverDescriptor)
        var sendBuffer: Int32 = 4_096
        XCTAssertEqual(
            setsockopt(serverDescriptor, SOL_SOCKET, SO_SNDBUF, &sendBuffer, socklen_t(MemoryLayout<Int32>.size)),
            0
        )

        let writeResult = MacClippySocketWriteResult()
        let writeFinished = expectation(description: "write returns after peer closes")
        let descriptorForWriting = serverDescriptor
        DispatchQueue.global(qos: .utility).async {
            let result = MacClippyUnixSocketLineTransport.writeLine(
                Data(repeating: 0x57, count: 1_048_576),
                to: descriptorForWriting,
                timeout: 2
            )
            writeResult.set(result)
            writeFinished.fulfill()
        }

        XCTAssertTrue(Self.waitUntilReadable(clientDescriptor, timeout: 1))
        var firstByte: UInt8 = 0
        XCTAssertEqual(Darwin.recv(clientDescriptor, &firstByte, 1, 0), 1)
        close(clientDescriptor)
        clientDescriptor = -1

        wait(for: [writeFinished], timeout: 3)
        XCTAssertEqual(writeResult.value, false)
        let closedServerDescriptor = serverDescriptor
        close(serverDescriptor)
        serverDescriptor = -1
        assertDescriptorClosed(closedServerDescriptor)
    }

    func testWriteLineCompletesWithOneKiBReceiveBufferAndDrainingPeer() throws {
        let descriptors = try makeSocketPair()
        var serverDescriptor = descriptors[0]
        var clientDescriptor = descriptors[1]
        defer {
            if serverDescriptor >= 0 { close(serverDescriptor) }
            if clientDescriptor >= 0 { close(clientDescriptor) }
        }
        try setNonblocking(serverDescriptor)
        try setNonblocking(clientDescriptor)
        setReceiveBuffer(clientDescriptor, to: 1_024)
        let (received, readerFinished) = startDelayedReader(clientDescriptor)

        let body = Data(repeating: 0x57, count: 65_536)
        XCTAssertTrue(MacClippyUnixSocketLineTransport.writeLine(body, to: serverDescriptor, timeout: 3))
        wait(for: [readerFinished], timeout: 4)
        XCTAssertEqual(received.value, body + Data([0x0A]))

        close(serverDescriptor)
        serverDescriptor = -1
        close(clientDescriptor)
        clientDescriptor = -1
    }

    private func setReceiveBuffer(_ descriptor: Int32, to requestedValue: Int32) {
        var receiveBuffer = requestedValue
        XCTAssertEqual(
            setsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, &receiveBuffer, socklen_t(MemoryLayout<Int32>.size)),
            0
        )
        var actualValue: Int32 = 0
        var actualValueLength = socklen_t(MemoryLayout<Int32>.size)
        XCTAssertEqual(
            getsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, &actualValue, &actualValueLength),
            0
        )
        XCTAssertEqual(actualValue, requestedValue)
    }

    private func startDelayedReader(
        _ descriptor: Int32
    ) -> (MacClippySocketReceivedBytes, XCTestExpectation) {
        let received = MacClippySocketReceivedBytes()
        let readerFinished = expectation(description: "draining reader reaches the complete line")
        DispatchQueue.global(qos: .utility).async {
            Thread.sleep(forTimeInterval: 0.25)
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            let deadline = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
            while !data.contains(0x0A), DispatchTime.now().uptimeNanoseconds < deadline {
                guard Self.waitUntilReadable(descriptor, timeout: 0.1) else { continue }
                let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
                if count > 0 {
                    data.append(contentsOf: buffer.prefix(count))
                } else if count < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
                    continue
                } else {
                    break
                }
            }
            received.set(data)
            readerFinished.fulfill()
        }
        return (received, readerFinished)
    }

    func testWriteDeadlineReturnsFalseAfterPartialProgress() throws {
        let descriptors = try makeSocketPair()
        var serverDescriptor = descriptors[0]
        var clientDescriptor = descriptors[1]
        defer {
            if serverDescriptor >= 0 { close(serverDescriptor) }
            if clientDescriptor >= 0 { close(clientDescriptor) }
        }
        try setNonblocking(serverDescriptor)

        let start = DispatchTime.now().uptimeNanoseconds
        let succeeded = MacClippyUnixSocketLineTransport.writeLine(
            Data(repeating: 0x57, count: 1_048_576),
            to: serverDescriptor,
            timeout: 0.05
        )
        let elapsedMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        XCTAssertFalse(succeeded)
        XCTAssertGreaterThanOrEqual(elapsedMilliseconds, 35)
        XCTAssertLessThan(elapsedMilliseconds, 500)

        let closedServerDescriptor = serverDescriptor
        let closedClientDescriptor = clientDescriptor
        close(serverDescriptor)
        serverDescriptor = -1
        close(clientDescriptor)
        clientDescriptor = -1
        assertDescriptorClosed(closedServerDescriptor)
        assertDescriptorClosed(closedClientDescriptor)
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

    private static func waitUntilReadable(_ descriptor: Int32, timeout: TimeInterval) -> Bool {
        var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        let timeoutMilliseconds = Int32(max(0, min(timeout * 1_000, Double(Int32.max))))
        let result = Darwin.poll(&pollDescriptor, 1, timeoutMilliseconds)
        return result > 0 && pollDescriptor.revents & Int16(POLLIN | POLLERR | POLLHUP) != 0
    }

    private func assertDescriptorClosed(_ descriptor: Int32) {
        XCTAssertEqual(fcntl(descriptor, F_GETFD), -1)
        XCTAssertEqual(errno, EBADF)
    }
}

private final class MacClippySocketWriteResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Bool?
    func set(_ value: Bool) { lock.lock(); storedValue = value; lock.unlock() }
    var value: Bool? { lock.lock(); defer { lock.unlock() }; return storedValue }
}

private final class MacClippySocketReceivedBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Data?
    func set(_ value: Data) { lock.lock(); storedValue = value; lock.unlock() }
    var value: Data? { lock.lock(); defer { lock.unlock() }; return storedValue }
}
