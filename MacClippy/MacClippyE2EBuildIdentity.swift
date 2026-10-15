enum MacClippyE2EBuildIdentity {
    static let bundleIdentifier = "com.macallyouneed.macclippy.e2e"

    static func allowsStartup(bundleIdentifier: String?, e2eFlagEnabled: Bool) -> Bool {
        if e2eFlagEnabled {
            return bundleIdentifier == Self.bundleIdentifier
        }
        return bundleIdentifier != Self.bundleIdentifier
    }
}

enum MacClippyE2ERetentionConfiguration {
    static let maximumItemLimit = 200_000
    static let defaultMaximumItems = maximumItemLimit

    enum ConfigurationError: Error {
        case invalidMaximumItems
    }

    static func maximumItems(environment: [String: String]) throws -> Int {
        guard let rawValue = environment["MACCLIPPY_E2E_RETENTION_MAX_ITEMS"] else {
            return defaultMaximumItems
        }
        guard !rawValue.isEmpty,
              rawValue.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let value = Int(rawValue), (1...maximumItemLimit).contains(value) else {
            throw ConfigurationError.invalidMaximumItems
        }
        return value
    }
}
