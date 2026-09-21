import AppKit
import SwiftUI
import UniformTypeIdentifiers

import MacClippyCore

extension MacClippyDockView {
    func handleDrop(_ providers: [NSItemProvider], on pinboard: MacClippyPinboardEntry) -> Bool {
        let expectedSession = model.currentSessionGeneration
        let recordType = MacClippyCardDragPolicy.recordTypeIdentifier
        let resolvedType = MacClippyClipboardDropPolicy.preferredTypeIdentifier(
            among: providers.flatMap(\.registeredTypeIdentifiers)
        ) ?? recordType
        guard let provider = providers.first(where: {
            $0.registeredTypeIdentifiers.contains(resolvedType) ||
            $0.hasItemConformingToTypeIdentifier(resolvedType) ||
            $0.registeredTypeIdentifiers.contains(recordType) ||
            $0.hasItemConformingToTypeIdentifier(recordType)
        }) else {
            return false
        }
        dropConfirmationGeneration &+= 1
        let confirmationGeneration = dropConfirmationGeneration
        dropConfirmedPinboardID = pinboard.id

        let loadType = provider.registeredTypeIdentifiers.contains(resolvedType) ? resolvedType : recordType
        provider.loadDataRepresentation(forTypeIdentifier: loadType) { data, _ in
            guard let data,
                  let payload = String(data: data, encoding: .utf8),
                  let recordID = MacClippyClipboardDropPolicy.recordID(from: payload) else {
                DispatchQueue.main.async {
                    if dropConfirmationGeneration == confirmationGeneration {
                        dropConfirmedPinboardID = nil
                    }
                }
                return
            }
            DispatchQueue.main.async {
                model.pin(recordID: recordID, to: pinboard, expectedSession: expectedSession) { success in
                    guard success, model.currentSessionGeneration == expectedSession else {
                        if dropConfirmationGeneration == confirmationGeneration {
                            dropConfirmedPinboardID = nil
                        }
                        return
                    }
                    Task { @MainActor in
                        let lifetime = UInt64(MacClippyMotion.dropConfirmationLifetime * 1_000_000_000)
                        try? await Task.sleep(nanoseconds: lifetime)
                        guard dropConfirmationGeneration == confirmationGeneration,
                              dropConfirmedPinboardID == pinboard.id,
                              model.currentSessionGeneration == expectedSession else { return }
                        dropConfirmedPinboardID = nil
                    }
                }
            }
        }
        return true
    }

    func handleSnippetDrop(_ providers: [NSItemProvider]) -> Bool {
        let expectedSession = model.currentSessionGeneration
        let recordType = MacClippyCardDragPolicy.recordTypeIdentifier
        let resolvedType = MacClippyClipboardDropPolicy.preferredTypeIdentifier(
            among: providers.flatMap(\.registeredTypeIdentifiers)
        ) ?? recordType
        guard let provider = providers.first(where: {
            $0.registeredTypeIdentifiers.contains(resolvedType) ||
            $0.hasItemConformingToTypeIdentifier(resolvedType) ||
            $0.registeredTypeIdentifiers.contains(recordType) ||
            $0.hasItemConformingToTypeIdentifier(recordType)
        }) else {
            return false
        }
        dropConfirmationGeneration &+= 1
        let confirmationGeneration = dropConfirmationGeneration
        dropConfirmedSnippets = true

        let loadType = provider.registeredTypeIdentifiers.contains(resolvedType) ? resolvedType : recordType
        provider.loadDataRepresentation(forTypeIdentifier: loadType) { data, _ in
            guard let data,
                  let payload = String(data: data, encoding: .utf8),
                  let recordID = MacClippyClipboardDropPolicy.recordID(from: payload) else {
                DispatchQueue.main.async {
                    if dropConfirmationGeneration == confirmationGeneration {
                        dropConfirmedSnippets = false
                    }
                }
                return
            }
            DispatchQueue.main.async {
                model.createSnippet(from: recordID, expectedSession: expectedSession) { success in
                    guard success, model.currentSessionGeneration == expectedSession else {
                        if dropConfirmationGeneration == confirmationGeneration {
                            dropConfirmedSnippets = false
                        }
                        return
                    }
                    Task { @MainActor in
                        let lifetime = UInt64(MacClippyMotion.dropConfirmationLifetime * 1_000_000_000)
                        try? await Task.sleep(nanoseconds: lifetime)
                        guard dropConfirmationGeneration == confirmationGeneration,
                              dropConfirmedSnippets,
                              model.currentSessionGeneration == expectedSession else { return }
                        dropConfirmedSnippets = false
                    }
                }
            }
        }
        return true
    }

    func actionFeedbackView(_ feedback: MacClippyDockActionFeedback) -> some View {
        Label(feedback.title, systemImage: feedback.systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(MacClippyDockTheme.textColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(MacClippyDockTheme.panelStrongColor, in: Capsule())
            .pillBorder(MacClippyDockTheme.pillRestBorder)
            .shadow(color: .black.opacity(0.14), radius: 14, y: 6)
            .lineLimit(1)
            .allowsHitTesting(false)
    }
}
