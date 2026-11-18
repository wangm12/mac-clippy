import AppKit
import Foundation
import UniformTypeIdentifiers

import MacClippyCore

enum MacClippyPasteboardPrivacyTextFilter {
    private enum RepresentationKind: Equatable {
        case plain, html, rtf, rtfd, opaque, binary
    }

    static func shouldExclude(_ change: PasteboardChange, rules: CaptureExclusionRules) -> Bool {
        guard !rules.excludedTextPatterns.isEmpty else { return false }
        guard var evaluation = rules.preparedTextExclusionEvaluation(), evaluation.isWithinBudget else { return true }
        for item in change.items {
            var seenTypes = Set<String>()
            for type in item.types where seenTypes.insert(type).inserted
                && shouldExclude(item, type: type, evaluation: &evaluation) {
                return true
            }
        }
        return !evaluation.isWithinBudget
    }

    private static func shouldExclude(
        _ item: PasteboardItem,
        type: String,
        evaluation: inout MacClippyCaptureTextExclusionEvaluation
    ) -> Bool {
        guard evaluation.isWithinBudget else { return true }
        let kind = representationKind(type)
        guard kind != .binary else { return false }
        guard let data = item.data(forType: type) else { return kind != .opaque }
        if kind == .opaque && data.isEmpty { return false }
        guard evaluation.allowRepresentation(byteCount: data.count) else { return true }
        return excludes(data, type: type, kind: kind, evaluation: &evaluation)
    }

    private static func excludes(
        _ data: Data,
        type: String,
        kind: RepresentationKind,
        evaluation: inout MacClippyCaptureTextExclusionEvaluation
    ) -> Bool {
        if kind == .opaque {
            guard let text = decodedText(data, type: type) else {
                return hasTextByteOrderMark(data) || !evaluation.isWithinBudget
            }
            return evaluation.shouldExcludeText(text)
        }
        // RTFD wrappers cannot be established as text without another native
        // document importer. Preserve them normally when no rules are enabled;
        // with privacy rules, reject instead of trusting an uninspected wrapper.
        if kind == .rtfd { return true }
        if kind == .rtf { return excludesRTF(data, evaluation: &evaluation) }
        guard let text = decodedText(data, type: type) else { return true }
        if evaluation.shouldExcludeText(text) { return true }
        guard kind == .html else { return false }
        // Check both retained source (including comments/attributes) and the
        // rendered text, where entities can hide a match from the raw source.
        let budget = evaluation
        guard let texts = MacClippyPasteboardPrivacyHTML.texts(text, isWithinBudget: { budget.isWithinBudget }) else {
            return true
        }
        var checked = Set([text])
        for variant in [texts.source, texts.rendered, texts.separated, texts.collapsed]
            where checked.insert(variant).inserted && evaluation.shouldExcludeText(variant) {
            return true
        }
        return !evaluation.isWithinBudget
    }

    private static func excludesRTF(_ data: Data, evaluation: inout MacClippyCaptureTextExclusionEvaluation) -> Bool {
        if let source = String(data: data, encoding: .utf8), evaluation.shouldExcludeText(source) { return true }
        let budget = evaluation
        guard let texts = MacClippyPasteboardPrivacyRTF.texts(
            data, isWithinBudget: { budget.isWithinBudget }
        ) else { return true }
        return excludes(texts, evaluation: &evaluation)
    }

    private static func excludes(
        _ texts: (source: String, rendered: String),
        evaluation: inout MacClippyCaptureTextExclusionEvaluation
    ) -> Bool {
        if evaluation.shouldExcludeText(texts.source) { return true }
        return texts.rendered != texts.source && evaluation.shouldExcludeText(texts.rendered)
    }

    private static func representationKind(_ identifier: String) -> RepresentationKind {
        if identifier == NSPasteboard.PasteboardType.rtfd.rawValue { return .rtfd }
        if identifier == "com.apple.rtfd" || identifier == "public.rtfd" { return .rtfd }
        guard let type = UTType(identifier) else { return .opaque }
        if type.conforms(to: .rtfd) { return .rtfd }
        if type.conforms(to: .rtf) { return .rtf }
        if type.conforms(to: .html) { return .html }
        if type.conforms(to: .text) { return .plain }
        if type.conforms(to: .image) || type.conforms(to: .audio) || type.conforms(to: .movie)
            || type.conforms(to: .pdf) || type.conforms(to: .archive) { return .binary }
        return .opaque
    }

    private static func decodedText(_ data: Data, type: String) -> String? {
        if data.starts(with: [0xFF, 0xFE, 0x00, 0x00]) || data.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
            return String(data: data, encoding: .utf32)
        }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return String(data: data.dropFirst(3), encoding: .utf8) }
        if type == "public.utf16-plain-text" { return String(data: data, encoding: .utf16LittleEndian) }
        if type == "public.utf16-external-plain-text" { return String(data: data, encoding: .utf16BigEndian) }
        return String(data: data, encoding: .utf8)
    }

    private static func hasTextByteOrderMark(_ data: Data) -> Bool {
        data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF])
            || data.starts(with: [0x00, 0x00, 0xFE, 0xFF]) || data.starts(with: [0xEF, 0xBB, 0xBF])
    }
}
