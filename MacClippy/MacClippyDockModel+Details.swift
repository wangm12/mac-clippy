import AppKit
import Foundation
import MacClippyCore
import MacClippyPlatform
import SwiftUI

extension MacClippyDockModel {
    func loadDetails(
        for id: RecordID,
        completion: @escaping @MainActor @Sendable (Result<MacClippyItemDetails, Error>) -> Void
    ) {
        detailsCancellationToken?.cancel()
        let cancellationToken = MacClippyCancellationToken()
        detailsCancellationToken = cancellationToken
        let runtimeReference = runtime
        let session = sessionGeneration
        workQueue.async { [weak self, runtimeReference, cancellationToken] in
            guard !cancellationToken.isCancelled else { return }
            let result = Result { try runtimeReference.details(id: id) }
            MacClippyMainHop.async { [weak self] in
                guard let self,
                    !cancellationToken.isCancelled,
                    self.sessionGeneration == session
                else { return }
                completion(result)
            }
        }
    }

    func editDetails(
        id: RecordID,
        text: String,
        completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void
    ) {
        let runtimeReference = runtime
        let session = sessionGeneration
        workQueue.async { [weak self, runtimeReference] in
            let result = Result { _ = try runtimeReference.edit(id: id, text: text) }
            MacClippyMainHop.async { [weak self] in
                guard let self, self.sessionGeneration == session else { return }
                completion(result.map { _ in () })
                if case .success = result {
                    self.reload()
                }
            }
        }
    }

    func renameDetails(
        id: RecordID,
        name: String?,
        completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void
    ) {
        let runtimeReference = runtime
        let session = sessionGeneration
        workQueue.async { [weak self, runtimeReference] in
            let result = Result { _ = try runtimeReference.setCustomLabel(id: id, label: name) }
            MacClippyMainHop.async { [weak self] in
                guard let self, self.sessionGeneration == session else { return }
                completion(result.map { _ in () })
                if case .success = result {
                    self.reload()
                }
            }
        }
    }

}
