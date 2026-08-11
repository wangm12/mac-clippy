import Foundation
import SwiftUI

enum MacClippyPrivacyNoticePolicy {
    static let acknowledgedKey = "com.macallyouneed.macclippy.privacyNoticeAcknowledged"

    static let title = "Before you start with Mac Clippy"
    static let settingsTitle = "Mac Clippy Privacy & Data Notice"

    static let message = """
    Mac Clippy keeps a local history of clipboard items so you can search, preview, copy, and paste them later.

    Clipboard payloads and image blobs are encrypted with a key in Keychain.
    Previews, OCR text, custom names, and search metadata are stored locally.
    Diagnostics and backups are user-triggered local actions.

    By default, concealed, transient, auto-generated, and common password-manager content is excluded. You can pause capture, add app or text exclusions, set retention limits, enable the advanced Capture All option, and delete history in Settings. Deleting history removes the record, search entry, OCR text, representation data, and associated blobs when they are no longer shared by another record.

    Accessibility enables automatic paste and Snippet expansion. Input Monitoring enables the global shortcut and Snippet trigger monitoring. Without those permissions, search, copy, and manual paste remain available.

    The current build makes no network calls. Clipboard data stays on this Mac unless you explicitly export diagnostics or create a backup. A formal public privacy-policy URL must be supplied by the product owner before distribution.
    """

    static func shouldPresent(defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: acknowledgedKey)
    }

    static func acknowledge(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: acknowledgedKey)
    }
}

struct MacClippyPrivacyNoticeView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(MacClippyPrivacyNoticePolicy.settingsTitle)
                .font(.title2)
                .fontWeight(.semibold)

            ScrollView {
                Text(MacClippyPrivacyNoticePolicy.message)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560, height: 480)
    }
}
