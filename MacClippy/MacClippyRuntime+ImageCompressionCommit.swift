import Foundation
import UniformTypeIdentifiers
import MacClippyCore

extension MacClippyRuntime {
    func isImageRepresentation(_ uti: String) -> Bool {
        UTType(uti)?.conforms(to: .image) == true
    }

    func commitCompression(
        _ prepared: MacClippyPreparedImageCompression,
        snapshot: MacClippyImageCompressionSnapshot,
        retiredBlobIDs: Set<String>,
        operation: MacClippyMaintenanceIOCoordinator.Operation,
        lifecycle: MacClippyImageCompressionLifecycle
    ) throws -> Bool {
        var replacementWritten = false
        let commit: () throws -> Bool = {
            guard !operation.isCancelled,
                  self.isCompressionLifecycleCurrent(lifecycle) else { throw CancellationError() }
            guard let currentMeta = try self.revalidatedCompressionMeta(for: snapshot) else {
                return false
            }
            guard !operation.isCancelled,
                  self.isCompressionLifecycleCurrent(lifecycle) else { throw CancellationError() }
            let replacement: ClipboardRecord = snapshot.encrypted
                ? .encryptedImage(blobID: prepared.blobID, width: prepared.width, height: prepared.height)
                : .image(blobID: prepared.blobID, width: prepared.width, height: prepared.height)
            _ = try self.clipboardStore.update(
                id: snapshot.meta.id,
                with: replacement,
                representations: prepared.representations,
                contentHash: prepared.contentHash,
                now: currentMeta.modified
            )
            replacementWritten = true
            for blobID in try self.clipboardStore.unreferencedBlobIDsWithoutBackfill(retiredBlobIDs) {
                try self.blobStore.delete(id: blobID)
            }
            return true
        }
        do {
            if let token = lifecycle.token {
                guard let result = try withCurrentLifecycleStoreLock(token, commit) else {
                    throw CancellationError()
                }
                return result
            }
            return try withStoreLock(commit)
        } catch {
            if !replacementWritten {
                removeUnreferencedCompressionBlob(prepared.blobID, operation: operation)
            }
            throw error
        }
    }

    func revalidatedCompressionMeta(
        for snapshot: MacClippyImageCompressionSnapshot
    ) throws -> ClipboardItemMeta? {
        guard let currentMeta = try clipboardStore.metas(for: [snapshot.meta.id]).first,
              currentMeta.modified == snapshot.meta.modified,
              currentMeta.lamport == snapshot.meta.lamport,
              let current = try? clipboardStore.playbackSnapshot(for: snapshot.meta.id),
              current.record == snapshot.body,
              current.representations == snapshot.representations,
              !(try PinboardStore.protectedIDs(from: pinboardStore)).contains(snapshot.meta.id) else {
            return nil
        }
        return currentMeta
    }

    func imageCompressionSnapshot(
        for listedMeta: ClipboardItemMeta,
        operation: MacClippyMaintenanceIOCoordinator.Operation
    ) throws -> MacClippyImageCompressionSnapshot? {
        try withStoreLock {
            guard !operation.isCancelled,
                  let meta = try clipboardStore.metas(for: [listedMeta.id]).first,
                  meta.modified == listedMeta.modified,
                  meta.lamport == listedMeta.lamport,
                  !(try PinboardStore.protectedIDs(from: pinboardStore)).contains(meta.id) else {
                return nil
            }
            let playback = try clipboardStore.playbackSnapshot(for: meta.id)
            let body = playback.record
            guard meta.contentKind == nil || meta.contentKind == body.contentKind else {
                throw MacClippyStoreError.invalidStoredRecord
            }
            let blobID: String
            let width: Int
            let height: Int
            let encrypted: Bool
            switch body {
            case let .image(id, storedWidth, storedHeight):
                (blobID, width, height, encrypted) = (id, storedWidth, storedHeight, false)
            case let .encryptedImage(id, storedWidth, storedHeight):
                (blobID, width, height, encrypted) = (id, storedWidth, storedHeight, true)
            default:
                return nil
            }
            let representations = playback.representations
            let sourceLease = try blobStore.acquireReadLease(
                for: Set([blobID] + representations.compactMap(\.blobID))
            )
            return MacClippyImageCompressionSnapshot(
                meta: meta,
                body: body,
                blobID: blobID,
                width: width,
                height: height,
                representations: representations,
                imageItemIndex: primaryImageItemIndex(in: representations),
                encrypted: encrypted,
                sourceLease: sourceLease
            )
        }
    }

    func primaryImageItemIndex(in representations: [MacClippyClipboardRepresentation]) -> Int {
        let available = representations.filter {
            $0.payloadState == .present || $0.payloadState == .spilled
        }
        for uti in ["public.png", "public.tiff"] {
            if let representation = available.first(where: { $0.uti == uti }) {
                return representation.itemIndex
            }
        }
        return available
            .filter { isImageRepresentation($0.uti) }
            .sorted { lhs, rhs in
                if lhs.itemIndex != rhs.itemIndex { return lhs.itemIndex < rhs.itemIndex }
                return lhs.uti < rhs.uti
            }
            .first?.itemIndex ?? 0
    }

    func checkCompressionCancellation(
        _ operation: MacClippyMaintenanceIOCoordinator.Operation,
        lifecycle: MacClippyImageCompressionLifecycle
    ) throws {
        guard !operation.isCancelled, isCompressionLifecycleCurrent(lifecycle) else {
            throw CancellationError()
        }
    }

    func isCompressionLifecycleCurrent(_ lifecycle: MacClippyImageCompressionLifecycle) -> Bool {
        if let token = lifecycle.token { return isCurrentLifecycleToken(token) }
        return withLifecycleStateLock { lifecycleGeneration == lifecycle.generation }
    }

    func removeUnreferencedCompressionBlob(
        _ blobID: String,
        operation: MacClippyMaintenanceIOCoordinator.Operation
    ) {
        guard let candidates = try? withStoreLock({
            try clipboardStore.unreferencedBlobIDsWithoutBackfill([blobID])
        }), candidates.contains(blobID) else {
            return
        }
        guard let cleanupIO = operation.beginCriticalIO() else { return }
        defer { cleanupIO.release() }
        try? blobStore.delete(id: blobID)
    }
}
