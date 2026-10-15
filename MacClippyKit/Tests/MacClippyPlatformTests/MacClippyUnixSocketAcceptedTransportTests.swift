import Darwin
import Foundation
import XCTest

@testable import MacClippyPlatform

final class MacClippySocketAcceptedTests: XCTestCase {
    func testReadRetriesAfterPollIsInterrupted() throws {
        let descriptors = try makeSocketPair()
        var serverDescriptor = descriptors[0]
        var clientDescriptor = descriptors[1]
        defer {
            if serverDescriptor >= 0 { close(serverDescriptor) }
            if clientDescriptor >= 0 { close(clientDescriptor) }
        }
        try setNonblocking(serverDescriptor)

        let interruptCounter = MacClippySocketAcceptedInterruptCounter()
        let wouldBlock = expectation(description: "read observes EAGAIN before poll")
        let interrupted = expectation(description: "poll reports EINTR and retries")
        let readFinished = expectation(description: "read returns at its original deadline")
        let readResult = MacClippySocketAcceptedReadResult()
        let pollInjection = MacClippySocketAcceptedPollInjection()
        let start = DispatchTime.now().uptimeNanoseconds
        let line = MacClippyUnixSocketLineTransport.readLine(
            from: serverDescriptor,
            maximumBytes: 128,
            timeout: 0.08,
            onWouldBlock: { wouldBlock.fulfill() },
            onInterrupted: {
                if interruptCounter.incrementAndGet() == 1 {
                    interrupted.fulfill()
                }
            },
            pollResultOverride: {
                guard pollInjection.shouldInterruptOnce() else { return nil }
                errno = EINTR
                return -1
            }
        )
        let elapsedMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000

        readResult.set(line)
        readFinished.fulfill()
        wait(for: [wouldBlock, interrupted, readFinished], timeout: 1)
        XCTAssertEqual(interruptCounter.value, 1)
        XCTAssertNil(readResult.value)
        XCTAssertGreaterThanOrEqual(elapsedMilliseconds, 60)
        XCTAssertLessThan(elapsedMilliseconds, 500)
        close(serverDescriptor)
        close(clientDescriptor)
        assertDescriptorClosed(serverDescriptor)
        assertDescriptorClosed(clientDescriptor)
        serverDescriptor = -1
        clientDescriptor = -1
    }

    func testAcceptedSocketRemainsHealthyAfterIncompletePeerCloses() throws {
        let (listener, socketPath) = try makeUnixListener()
        defer { close(listener) }
        defer {
            _ = unlink(socketPath)
        }
        try assertBadPeerCloseDoesNotWriteToUnusableSocket(listener, path: socketPath)
        try assertFollowingPingIsHealthy(listener, path: socketPath)
    }

    private func assertBadPeerCloseDoesNotWriteToUnusableSocket(_ listener: Int32, path: String) throws {
        var client = try connect(to: path)
        let accepted = try accept(listener)
        defer { if client >= 0 { close(client) } }
        defer { close(accepted) }
        try setNonblocking(accepted)
        XCTAssertTrue(sendAll(Data("{\"command\":".utf8), to: client))
        close(client)
        client = -1
        XCTAssertNil(
            MacClippyUnixSocketLineTransport.readLine(
                from: accepted,
                maximumBytes: 2 * 1_024 * 1_024,
                timeout: 1
            )
        )
        XCTAssertFalse(
            MacClippyUnixSocketLineTransport.writeLine(
                Data("{\"ok\":false,\"errorCode\":\"invalid-request\"}".utf8),
                to: accepted,
                timeout: 1
            )
        )
    }

    private func assertFollowingPingIsHealthy(_ listener: Int32, path: String) throws {
        var client = try connect(to: path)
        var accepted = try accept(listener)
        defer {
            if client >= 0 { close(client) }
            if accepted >= 0 { close(accepted) }
        }
        try setNonblocking(accepted)
        try setNonblocking(client)
        XCTAssertTrue(sendAll(Data("{\"command\":\"ping\"}\n".utf8), to: client))
        XCTAssertEqual(
            MacClippyUnixSocketLineTransport.readLine(
                from: accepted,
                maximumBytes: 2 * 1_024 * 1_024,
                timeout: 1
            ),
            Data("{\"command\":\"ping\"}".utf8)
        )

        XCTAssertTrue(
            MacClippyUnixSocketLineTransport.writeLine(
                Data("{\"ok\":true,\"ready\":true}".utf8),
                to: accepted,
                timeout: 1
            )
        )
        var lowWater: Int32 = 0
        var lowWaterLength = socklen_t(MemoryLayout<Int32>.size)
        XCTAssertEqual(
            getsockopt(accepted, SOL_SOCKET, SO_SNDLOWAT, &lowWater, &lowWaterLength),
            0
        )
        XCTAssertEqual(lowWater, 1)
        XCTAssertEqual(
            MacClippyUnixSocketLineTransport.readLine(
                from: client,
                maximumBytes: 1_024,
                timeout: 1
            ),
            Data("{\"ok\":true,\"ready\":true}".utf8)
        )

        let acceptedToVerify = accepted
        let clientToVerify = client
        close(accepted)
        accepted = -1
        close(client)
        client = -1
        assertDescriptorClosed(acceptedToVerify)
        assertDescriptorClosed(clientToVerify)
    }

    private func makeUnixListener() throws -> (Int32, String) {
        let socketPath = "/tmp/mct-\(UUID().uuidString).sock"
        guard socketPath.utf8.count + 1 < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENAMETOOLONG))
        }
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: pathBytes)
        }
        let bindResult = withUnsafePointer(to: &address) { addressPointer in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(descriptor, 4) == 0 else {
            let error = errno
            close(descriptor)
            _ = unlink(socketPath)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(error))
        }
        return (descriptor, socketPath)
    }

    private func connect(to socketPath: String) throws -> Int32 {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: pathBytes)
        }
        let connectResult = withUnsafePointer(to: &address) { addressPointer in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.connect(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            let error = errno
            close(descriptor)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(error))
        }
        return descriptor
    }

    private func accept(_ descriptor: Int32) throws -> Int32 {
        let accepted = Darwin.accept(descriptor, nil, nil)
        guard accepted >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return accepted
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

    private func assertDescriptorClosed(_ descriptor: Int32) {
        XCTAssertEqual(fcntl(descriptor, F_GETFD), -1)
        XCTAssertEqual(errno, EBADF)
    }
}

private final class MacClippySocketAcceptedReadResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Data?
    func set(_ value: Data?) { lock.lock(); storedValue = value; lock.unlock() }
    var value: Data? { lock.lock(); defer { lock.unlock() }; return storedValue }
}

private final class MacClippySocketAcceptedInterruptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    @discardableResult func incrementAndGet() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private final class MacClippySocketAcceptedPollInjection: @unchecked Sendable {
    private let lock = NSLock()
    private var hasInterrupted = false
    func shouldInterruptOnce() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !hasInterrupted else { return false }
        hasInterrupted = true
        return true
    }
}
