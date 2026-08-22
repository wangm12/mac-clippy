import AppKit
import Security

enum MacClippyPresentationPreferences {
    static let hideFromMenuBarKey = "com.macallyouneed.macclippy.presentation.hideFromMenuBar"
    static let hideDockIconKey = "com.macallyouneed.macclippy.presentation.hideDockIcon"
}

/// Pure presentation decisions shared by Settings and AppDelegate.
/// Menu-bar visibility and Dock activation remain independent preferences.
enum MacClippyCodeSignatureKind: Equatable {
    case teamSigned(teamID: String)
    case adhoc
    case unsigned
}

enum MacClippyPermissionTrustPolicy {
    static func kind(isSigned: Bool, isAdhoc: Bool, teamID: String?) -> MacClippyCodeSignatureKind {
        let trimmedTeam = teamID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if !isSigned {
            return .unsigned
        }
        if isAdhoc || trimmedTeam?.isEmpty != false {
            return .adhoc
        }
        return .teamSigned(teamID: trimmedTeam!)
    }

    static func permissionsCanPersist(_ kind: MacClippyCodeSignatureKind) -> Bool {
        if case .teamSigned = kind {
            return true
        }
        return false
    }

    static func unsignedCopyExplanation() -> String {
        "This copy is unsigned. macOS can show Grant Access without trusting the process. In Xcode, add an Apple Development certificate, run make dmg, replace /Applications/MacClippy.app, then grant access again."
    }
}

enum MacClippyCodeSignature {
    static func kind(for url: URL = Bundle.main.bundleURL) -> MacClippyCodeSignatureKind {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &staticCode)
        guard createStatus == errSecSuccess, let staticCode else {
            return .unsigned
        }

        var information: CFDictionary?
        let copyStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        )
        guard copyStatus == errSecSuccess, let information = information as? [String: Any] else {
            return .unsigned
        }

        let flags = (information[kSecCodeInfoFlags as String] as? UInt32)
            ?? (information[kSecCodeInfoFlags as String] as? Int).map(UInt32.init)
            ?? 0
        let teamID = information[kSecCodeInfoTeamIdentifier as String] as? String
        let identifier = information[kSecCodeInfoIdentifier as String] as? String
        let isSigned = identifier != nil || flags != 0
        let isAdhoc = flags & 0x0002 != 0
        return MacClippyPermissionTrustPolicy.kind(
            isSigned: isSigned,
            isAdhoc: isAdhoc,
            teamID: teamID
        )
    }
}

enum MacClippyPresentationPolicy {
    struct State: Equatable {
        let showsMenuBarIcon: Bool
        let activationPolicy: NSApplication.ActivationPolicy
    }

    static func state(hideFromMenuBar: Bool, hideDockIcon: Bool) -> State {
        State(
            showsMenuBarIcon: !hideFromMenuBar,
            activationPolicy: activationPolicy(hideDockIcon: hideDockIcon)
        )
    }

    static func activationPolicy(hideDockIcon: Bool) -> NSApplication.ActivationPolicy {
        hideDockIcon ? .accessory : .regular
    }
}
