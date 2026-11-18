import AppKit
import Foundation
import MacClippyCore
import UniformTypeIdentifiers

@MainActor
enum MacClippyBackupPassphrasePrompt {
    static let minimumLength = 8

    static func promptForCreation(
        title: String = "Encrypt Backup Archive",
        message: String = "Enter a passphrase (at least 8 characters). You will need it to restore on any Mac."
    ) -> String? {
        while true {
            guard let entered = runCreationDialog(title: title, message: message) else { return nil }
            if entered.passphrase.count < minimumLength {
                showValidationAlert("Passphrase must be at least \(minimumLength) characters.")
                continue
            }
            if entered.passphrase != entered.confirmation {
                showValidationAlert("Passphrase and confirmation do not match.")
                continue
            }
            return entered.passphrase
        }
    }

    static func promptForUnlock(
        title: String = "Enter Backup Passphrase",
        message: String = "Enter the passphrase used to encrypt this Mac Clippy backup archive."
    ) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "Passphrase"
        alert.accessoryView = field
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    static func showValidationAlert(_ text: String) {
        let alert = NSAlert()
        alert.messageText = "Cannot Use Passphrase"
        alert.informativeText = text
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func runCreationDialog(
        title: String,
        message: String
    ) -> (passphrase: String, confirmation: String)? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 280, height: 56))
        stack.orientation = .vertical
        stack.spacing = 8

        let passphraseField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        passphraseField.placeholderString = "Passphrase (8+ characters)"
        let confirmField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        confirmField.placeholderString = "Confirm passphrase"
        stack.addArrangedSubview(passphraseField)
        stack.addArrangedSubview(confirmField)

        alert.accessoryView = stack
        alert.addButton(withTitle: "Encrypt")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = passphraseField
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return (passphraseField.stringValue, confirmField.stringValue)
    }

    static func presentMissingKeychainRecovery(onRestore: () -> Void, onStartFresh: () -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Clipboard Encryption Key Missing"
        alert.informativeText = """
        Mac Clippy found existing clipboard data on this Mac, but its Keychain encryption key is \
        missing (for example after Migration Assistant or a Keychain reset). Restore from an \
        encrypted backup archive, archive the unreadable data to start fresh, or quit.
        """
        alert.addButton(withTitle: "Restore Backup…")
        alert.addButton(withTitle: "Archive Old Data & Start Fresh")
        alert.addButton(withTitle: "Quit")
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            onRestore()
        case .alertSecondButtonReturn:
            onStartFresh()
        default:
            NSApp.terminate(nil)
        }
    }

    static func archiveUnreadableStorage(at rootURL: URL) throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let archiveDir = rootURL.appendingPathComponent(
            "Archived-Unreadable-\(formatter.string(from: Date()))",
            isDirectory: true
        )
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: archiveDir, withIntermediateDirectories: true)
        for component in ["databases", "blobs", MacClippyThumbnailCachePolicy.directoryName] {
            let source = rootURL.appendingPathComponent(component, isDirectory: true)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let destination = archiveDir.appendingPathComponent(component, isDirectory: true)
            try fileManager.moveItem(at: source, to: destination)
        }
    }

    static func chooseArchiveURLForRecovery() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        let archiveType = UTType(filenameExtension: MacClippyBackupSettingsPolicy.archivePathExtension) ?? .data
        panel.allowedContentTypes = [archiveType]
        panel.prompt = "Restore"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    static func userMessage(for error: Error, fallback: String = "Backup operation failed.") -> String {
        if let backupError = error as? MacClippyBackupError {
            return MacClippyBackupSettingsPolicy.message(for: backupError)
        }
        return fallback
    }
}
