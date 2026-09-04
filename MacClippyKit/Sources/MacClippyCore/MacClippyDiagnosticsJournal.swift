import Foundation

public final class MacClippyDiagnosticsJournal: @unchecked Sendable {
    public static let shared = MacClippyDiagnosticsJournal()
    public static let defaultCapacity = 200

    private let lock = NSLock()
    private var url: URL?
    private var capacity: Int
    private var events: [MacClippyDiagnosticsEvent] = []

    public init(url: URL? = nil, capacity: Int = defaultCapacity) {
        self.url = url
        self.capacity = max(1, capacity)
        if let url {
            events = Self.load(from: url, capacity: self.capacity)
        }
    }

    public func activate(url: URL, capacity: Int = defaultCapacity) {
        lock.lock()
        self.url = url
        self.capacity = max(1, capacity)
        events = Self.load(from: url, capacity: self.capacity)
        lock.unlock()
    }

    public func record(_ event: MacClippyDiagnosticsEvent) {
        lock.lock()
        guard url != nil else {
            lock.unlock()
            return
        }
        events.append(event)
        if events.count > capacity {
            events.removeFirst(events.count - capacity)
        }
        let snapshot = events
        let url = self.url
        lock.unlock()
        if let url {
            Self.persist(snapshot, to: url)
        }
    }

    public func recentEvents() -> [MacClippyDiagnosticsEvent] {
        lock.lock()
        let snapshot = events
        lock.unlock()
        return snapshot
    }

    private static func load(from url: URL, capacity: Int) -> [MacClippyDiagnosticsEvent] {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        var loaded: [MacClippyDiagnosticsEvent] = []
        loaded.reserveCapacity(min(capacity, 32))
        for line in contents.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { continue }
            if let event = try? decoder.decode(MacClippyDiagnosticsEvent.self, from: data) {
                loaded.append(event)
            }
        }
        if loaded.count > capacity {
            loaded.removeFirst(loaded.count - capacity)
        }
        return loaded
    }

    private static func persist(_ events: [MacClippyDiagnosticsEvent], to url: URL) {
        let encoder = JSONEncoder()
        var lines: [String] = []
        lines.reserveCapacity(events.count)
        for event in events {
            guard let data = try? encoder.encode(event),
                  let line = String(data: data, encoding: .utf8) else { continue }
            lines.append(line)
        }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
