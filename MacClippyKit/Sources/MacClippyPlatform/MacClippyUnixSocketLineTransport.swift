import Darwin
import Foundation

/// Reads and writes newline-delimited messages on nonblocking Unix sockets.
public enum MacClippyUnixSocketLineTransport {
    private static let bufferSize = 8_192

    public static func readLine(
        from descriptor: Int32,
        maximumBytes: Int,
        timeout: TimeInterval
    ) -> Data? {
        readLine(from: descriptor, maximumBytes: maximumBytes, timeout: timeout, onWouldBlock: {})
    }

    static func readLine(
        from descriptor: Int32,
        maximumBytes: Int,
        timeout: TimeInterval,
        onWouldBlock: @Sendable () -> Void,
        onInterrupted: @Sendable () -> Void = {},
        pollResultOverride: (@Sendable () -> Int32?)? = nil
    ) -> Data? {
        guard let deadline = deadline(after: timeout), maximumBytes > 0 else { return nil }

        var message = Data()
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while true {
            let remainingBytes = maximumBytes - message.count
            let readLimit = min(buffer.count, remainingBytes + 1)
            switch receiveNextChunk(from: descriptor, into: &buffer, maximumLength: readLimit) {
            case .received(let count):
                let received = buffer.prefix(count)
                if let newline = received.firstIndex(of: 0x0A) {
                    guard message.count + newline <= maximumBytes else { return nil }
                    message.append(contentsOf: received[..<newline])
                    return message
                }
                guard count <= remainingBytes else { return nil }
                message.append(contentsOf: received)
            case .interrupted:
                continue
            case .wouldBlock:
                onWouldBlock()
                guard waitUntilReady(
                    descriptor,
                    events: Int16(POLLIN),
                    deadline: deadline,
                    onInterrupted: onInterrupted,
                    pollResultOverride: pollResultOverride
                ) else { return nil }
            case .finished:
                return nil
            }
        }
    }

    @discardableResult
    public static func writeLine(
        _ message: Data,
        to descriptor: Int32,
        timeout: TimeInterval
    ) -> Bool {
        guard let deadline = deadline(after: timeout) else { return false }
        guard configureWriteReadiness(descriptor) else { return false }

        var framedMessage = message
        framedMessage.append(0x0A)
        return framedMessage.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return false }
            var sentBytes = 0
            while sentBytes < bytes.count {
                let count = Darwin.send(
                    descriptor,
                    baseAddress.advanced(by: sentBytes),
                    bytes.count - sentBytes,
                    Int32(MSG_NOSIGNAL)
                )
                if count > 0 {
                    sentBytes += count
                    continue
                }
                if count < 0, errno == EINTR { continue }
                guard count < 0, errno == EAGAIN || errno == EWOULDBLOCK,
                      waitUntilReady(descriptor, events: Int16(POLLOUT), deadline: deadline) else {
                    return false
                }
            }
            return true
        }
    }

    private static func deadline(after timeout: TimeInterval) -> UInt64? {
        guard timeout.isFinite, timeout > 0, timeout <= 300 else { return nil }
        let interval = UInt64(timeout * 1_000_000_000)
        return DispatchTime.now().uptimeNanoseconds &+ interval
    }

    private static func receiveNextChunk(
        from descriptor: Int32,
        into buffer: inout [UInt8],
        maximumLength: Int
    ) -> ReceiveResult {
        let count = buffer.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return -1 }
            return Darwin.recv(descriptor, baseAddress, maximumLength, 0)
        }
        if count > 0 { return .received(count) }
        if count == 0 { return .finished }
        if errno == EINTR { return .interrupted }
        if errno == EAGAIN || errno == EWOULDBLOCK { return .wouldBlock }
        return .finished
    }

    private static func configureWriteReadiness(_ descriptor: Int32) -> Bool {
        // poll(POLLOUT) honors SO_SNDLOWAT. Lower it so a draining peer with a
        // small receive buffer can make progress as soon as any space opens.
        var sendLowWater: Int32 = 1
        return setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_SNDLOWAT,
            &sendLowWater,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0
    }

    private static func waitUntilReady(
        _ descriptor: Int32,
        events: Int16,
        deadline: UInt64,
        onInterrupted: @Sendable () -> Void = {},
        pollResultOverride: (@Sendable () -> Int32?)? = nil
    ) -> Bool {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return false }
            let remaining = deadline - now
            let roundedMilliseconds = (remaining + 999_999) / 1_000_000
            let timeoutMilliseconds = Int32(min(roundedMilliseconds, UInt64(Int32.max)))
            var pollDescriptor = pollfd(fd: descriptor, events: events, revents: 0)
            let result = pollResultOverride?() ?? Darwin.poll(&pollDescriptor, 1, timeoutMilliseconds)
            if result > 0 {
                let readyEvents = pollDescriptor.revents
                return readyEvents & (events | Int16(POLLERR) | Int16(POLLHUP)) != 0
            }
            if result == 0 { return false }
            if errno != EINTR { return false }
            onInterrupted()
        }
    }

    private enum ReceiveResult {
        case received(Int)
        case interrupted
        case wouldBlock
        case finished
    }
}
