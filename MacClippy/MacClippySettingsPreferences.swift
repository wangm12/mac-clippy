import Foundation
import MacClippyCore
import MacClippyPlatform

enum MacClippyRetentionPreferences {
    static let maxItemsKey = "com.macallyouneed.macclippy.retention.maxItems"
    static let maxAgeDaysKey = "com.macallyouneed.macclippy.retention.maxAgeDays"
    static let maxImageMegabytesKey = "com.macallyouneed.macclippy.retention.maxImageMegabytes"
    static let maxHistoryMegabytesKey = "com.macallyouneed.macclippy.retention.maxHistoryMegabytes"
    static let captureAllKey = "com.macallyouneed.macclippy.capture.captureAll"
    static let excludeConcealedKey = "com.macallyouneed.macclippy.capture.excludeConcealed"
    static let excludeTransientKey = "com.macallyouneed.macclippy.capture.excludeTransient"
    static let excludedAppsKey = "com.macallyouneed.macclippy.capture.excludedApps"
    static let excludedTextPatternsKey = "com.macallyouneed.macclippy.capture.excludedTextPatterns"
    static let privacyPauseKey = "com.macallyouneed.macclippy.capture.privacyPause"
    static let pauseDurationSecondsKey = "com.macallyouneed.macclippy.capture.pauseDurationSeconds"
    static let pauseUntilKey = "com.macallyouneed.macclippy.capture.pauseUntil"
    static let launchAtLoginKey = "com.macallyouneed.macclippy.launchAtLogin"
    static let alwaysPastePlainTextKey = "com.macallyouneed.macclippy.paste.alwaysPlainText"

    static let defaultMaxItems = MacClippyStorageCapPolicy.defaultMaxItems
    static let defaultMaxAgeDays = 0
    static let defaultMaxImageMegabytes = MacClippyStorageCapPolicy.defaultMaxImageMegabytes
    static let defaultMaxHistoryMegabytes = MacClippyStorageCapPolicy.defaultMaxHistoryMegabytes

    static func policy(from defaults: UserDefaults = .standard) -> RetentionPolicy {
        let maxItems: Int
        let maxImageMegabytes: Int
        let maxHistoryMegabytes: Int
        if MacClippyStorageCapPolicy.exposesSettingsEditors {
            maxItems = MacClippyStorageCapPolicy.enforced(
                defaults.object(forKey: maxItemsKey) as? Int ?? defaultMaxItems,
                default: defaultMaxItems
            )
            maxImageMegabytes = MacClippyStorageCapPolicy.enforced(
                defaults.object(forKey: maxImageMegabytesKey) as? Int ?? defaultMaxImageMegabytes,
                default: defaultMaxImageMegabytes
            )
            maxHistoryMegabytes = MacClippyStorageCapPolicy.enforced(
                defaults.object(forKey: maxHistoryMegabytesKey) as? Int ?? defaultMaxHistoryMegabytes,
                default: defaultMaxHistoryMegabytes
            )
        } else {
            maxItems = defaultMaxItems
            maxImageMegabytes = defaultMaxImageMegabytes
            maxHistoryMegabytes = defaultMaxHistoryMegabytes
        }
        let maxAgeDays = MacClippyHistoryCapacity(
            maxAgeDays: defaults.object(forKey: maxAgeDaysKey) as? Int ?? defaultMaxAgeDays
        ).maxAgeDays
        return RetentionPolicy(
            maxItems: maxItems,
            maxAge: maxAgeDays > 0 ? TimeInterval(maxAgeDays) * 86_400 : nil,
            maxImageBytes: byteLimit(forMegabytes: maxImageMegabytes),
            maxTotalBytes: byteLimit(
                forMegabytes: maxHistoryMegabytes,
                cappedAt: MacClippyPasteboardInputLimits.default.maxHistoryBytes
            )
        )
    }

    private static func byteLimit(forMegabytes megabytes: Int, cappedAt maximumBytes: Int = .max) -> Int? {
        guard megabytes > 0 else { return nil }
        let bytesPerMegabyte = 1_024 * 1_024
        let safeMegabytes = min(megabytes, maximumBytes / bytesPerMegabyte)
        guard safeMegabytes > 0 else { return nil }
        return safeMegabytes * bytesPerMegabyte
    }

    static func pauseDuration(from defaults: UserDefaults = .standard) -> MacClippyTimedPauseDuration {
        MacClippyTimedPauseDuration(
            rawValue: defaults.object(forKey: pauseDurationSecondsKey) as? Int
                ?? MacClippyTimedPauseDuration.fiveMinutes.rawValue
        ) ?? .fiveMinutes
    }

    static func pauseUntil(from defaults: UserDefaults = .standard) -> Date? {
        guard defaults.object(forKey: pauseUntilKey) != nil else { return nil }
        return Date(timeIntervalSince1970: defaults.double(forKey: pauseUntilKey))
    }

    static func applyPause(
        enabled: Bool,
        duration: MacClippyTimedPauseDuration,
        now: Date = Date(),
        defaults: UserDefaults = .standard
    ) {
        defaults.set(enabled, forKey: privacyPauseKey)
        defaults.set(duration.rawValue, forKey: pauseDurationSecondsKey)
        if enabled {
            defaults.set(
                MacClippyCapturePausePolicy.endDate(now: now, duration: duration).timeIntervalSince1970,
                forKey: pauseUntilKey
            )
        } else {
            defaults.removeObject(forKey: pauseUntilKey)
        }
    }

    static func alwaysPastePlainText(from defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: alwaysPastePlainTextKey)
    }

    static func shouldPastePlain(shiftHeld: Bool, defaults: UserDefaults = .standard) -> Bool {
        MacClippyPastePlainTextPolicy.shouldPastePlain(
            alwaysPlain: alwaysPastePlainText(from: defaults),
            shiftHeld: shiftHeld
        )
    }

    static func exclusionRules(from defaults: UserDefaults = .standard) -> CaptureExclusionRules {
        let userExcludedApps = Set(
            defaults.string(forKey: excludedAppsKey)?
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty } ?? []
        )
        let excludedApps = CaptureExclusionRules.defaultExcludedAppBundleIDs.union(userExcludedApps)
        let excludedTextPatterns = (defaults.string(forKey: excludedTextPatternsKey) ?? "")
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let hasConcealedPreference = defaults.object(forKey: excludeConcealedKey) != nil
        let hasTransientPreference = defaults.object(forKey: excludeTransientKey) != nil
        return CaptureExclusionRules(
            concealedPasteboardTypes: hasConcealedPreference
                ? (defaults.bool(forKey: excludeConcealedKey) ? ["org.nspasteboard.ConcealedType"] : [])
                : CaptureExclusionRules.defaultConcealedPasteboardTypes,
            transientPasteboardTypes: hasTransientPreference
                ? (defaults.bool(forKey: excludeTransientKey) ? ["org.nspasteboard.TransientType"] : [])
                : CaptureExclusionRules.defaultTransientPasteboardTypes,
            excludedAppBundleIDs: excludedApps,
            excludedTextPatterns: excludedTextPatterns,
            captureAll: defaults.bool(forKey: captureAllKey)
        )
    }
}

enum MacClippyHistoryCapacity: Int, CaseIterable {
    case day
    case week
    case month
    case unlimited

    var maxAgeDays: Int {
        switch self {
        case .day: 1
        case .week: 7
        case .month: 30
        case .unlimited: 0
        }
    }

    var title: String {
        switch self {
        case .day: "Day"
        case .week: "Week"
        case .month: "Month"
        case .unlimited: "Unlimited"
        }
    }

    var index: Double { Double(rawValue) }

    init(maxAgeDays: Int) {
        self = Self.allCases.min {
            let distance = abs($0.maxAgeDays - maxAgeDays)
            let otherDistance = abs($1.maxAgeDays - maxAgeDays)
            return distance < otherDistance || (distance == otherDistance && $0.rawValue < $1.rawValue)
        } ?? .unlimited
    }

    init(index: Double) {
        let rounded = Int(index.rounded())
        self = Self(rawValue: min(max(rounded, 0), Self.allCases.count - 1)) ?? .unlimited
    }
}
