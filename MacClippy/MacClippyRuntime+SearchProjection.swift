import Foundation

import MacClippyCore
import MacClippyPlatform

extension MacClippyRuntime {
    // P2a: keep the persisted custom label and its FTS projection consistent.
    // A blank label removes only the label while preserving body/OCR text.
    @discardableResult
    func setCustomLabel(id: RecordID, label: String?) throws -> ClipboardItemMeta {
        try withStoreLock {
            let meta = try clipboardStore.setCustomLabel(id: id, label: label)
            let body = try clipboardStore.body(for: id)
            let indexText = Self.searchableIndexText(
                for: body,
                ocrText: meta.ocrText,
                label: meta.customLabel,
                representationUTIs: try clipboardStore.representationUTIs(for: id),
                sourceAppBundleID: meta.sourceAppBundleID
            )
            if indexText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                do {
                    try searchStore.remove(kind: .clipboardItem, id: id)
                } catch {
                    markSearchRepairNeededLocked()
                    MacClippyLog.record(
                        category: .fts,
                        code: .ftsIndexFailed,
                        operation: "label_fts_remove",
                        recoveryAction: "repair_search_index",
                        impact: "label_saved_but_search_state_needs_repair"
                    )
                    throw error
                }
            } else {
                do {
                    try searchStore.upsert(kind: .clipboardItem, id: id, text: indexText)
                } catch {
                    markSearchRepairNeededLocked()
                    MacClippyLog.record(
                        category: .fts,
                        code: .ftsIndexFailed,
                        operation: "label_fts_update",
                        recoveryAction: "repair_search_index",
                        impact: "label_saved_but_search_state_needs_repair"
                    )
                    throw error
                }
            }
            return meta
        }
    }

    static func searchableIndexText(
        for record: ClipboardRecord,
        ocrText: String?,
        label: String?,
        // Accepted so capture/repair call sites stay unchanged. Pasteboard
        // UTIs must not be indexed: `text`/`html`/`url` would match almost
        // every clip, and FTS snippets would show `public.html`.
        representationUTIs _: [String] = [],
        // Source-app tokens stay on the record for `app:` filters. Indexing
        // them makes bare `chat` / `codex` / `Safari` match every clip from
        // that app.
        sourceAppBundleID _: String? = nil,
        sourceAppDisplayName _: String? = nil
    ) -> String {
        var segments: [String] = []
        if let bodyText = MacClippyClipboardText.plainText(from: record),
           !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            segments.append(bodyText)
        }
        if let ocrText = ocrText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !ocrText.isEmpty {
            segments.append(ocrText)
        }
        if let label = label?.trimmingCharacters(in: .whitespacesAndNewlines),
           !label.isEmpty {
            segments.append(label)
        }
        if case let .files(urls) = record {
            segments.append(contentsOf: MacClippyFilePresentation.searchSegments(for: urls))
        }
        return MacClippySearchQuery.boundedUTF8Prefix(
            segments.joined(separator: "\n"),
            maxBytes: MacClippyRuntime.searchIndexTextByteLimit
        )
    }

    // Resolve uncached history projections in one envelope read. The fallback
    // keeps the previous per-record skip behavior if one damaged envelope
    // makes the batch decode fail; a corrupt card must not hide healthy cards.
    func entries(
        for metas: [ClipboardItemMeta],
        validateContentKind: Bool = false
    ) throws -> [RecordID: MacClippyHistoryEntry] {
        let cached = cachedHistoryEntries(for: metas, validateContentKind: validateContentKind)
        var entriesByID = cached.entriesByID
        let uncachedMetas = cached.uncachedMetas
        if !uncachedMetas.isEmpty {
            let bodyMetas = metadataOnlyHistoryEntries(
                for: uncachedMetas,
                entriesByID: &entriesByID
            )
            if !bodyMetas.isEmpty {
                if let batchEntries = try batchHistoryEntries(for: bodyMetas) {
                    entriesByID.merge(batchEntries) { _, newer in newer }
                } else {
                    for meta in bodyMetas {
                        if let entry = try entry(for: meta) {
                            entriesByID[meta.id] = entry
                        }
                    }
                }
            }
        }
        return try stampRemoteClipboard(entriesByID, metas: metas)
    }

    func stampRemoteClipboard(
        _ entries: [RecordID: MacClippyHistoryEntry],
        metas: [ClipboardItemMeta]
    ) throws -> [RecordID: MacClippyHistoryEntry] {
        guard !entries.isEmpty else { return entries }
        let remoteIDs = try clipboardStore.recordIDsContainingUTI(
            CaptureExclusionRules.remoteClipboardPasteboardType,
            in: Array(entries.keys)
        )
        var stamped: [RecordID: MacClippyHistoryEntry] = [:]
        stamped.reserveCapacity(entries.count)
        let metasByID = Dictionary(uniqueKeysWithValues: metas.map { ($0.id, $0) })
        for (id, entry) in entries {
            let next = entry.withRemoteClipboard(remoteIDs.contains(id))
            stamped[id] = next
            if let meta = metasByID[id] {
                historyEntryCache.setObject(
                    MacClippyHistoryEntryCacheBox(next),
                    forKey: cacheKey(for: meta),
                    cost: historyEntryCacheCost(next)
                )
            }
        }
        return stamped
    }

    private func cachedHistoryEntries(
        for metas: [ClipboardItemMeta],
        validateContentKind: Bool
    ) -> (entriesByID: [RecordID: MacClippyHistoryEntry], uncachedMetas: [ClipboardItemMeta]) {
        var entriesByID: [RecordID: MacClippyHistoryEntry] = [:]
        var uncachedMetas: [ClipboardItemMeta] = []
        entriesByID.reserveCapacity(metas.count)
        uncachedMetas.reserveCapacity(metas.count)
        for meta in metas {
            guard let cachedEntry = reusableCachedHistoryEntry(
                for: meta,
                validateContentKind: validateContentKind
            ) else {
                uncachedMetas.append(meta)
                continue
            }
            entriesByID[meta.id] = cachedEntry
        }
        return (entriesByID, uncachedMetas)
    }

    private func metadataOnlyHistoryEntries(
        for metas: [ClipboardItemMeta],
        entriesByID: inout [RecordID: MacClippyHistoryEntry]
    ) -> [ClipboardItemMeta] {
        var bodyMetas: [ClipboardItemMeta] = []
        bodyMetas.reserveCapacity(metas.count)
        for meta in metas {
            // Visible pages stay on meta+preview for every stored kind.
            // Decrypt envelopes and clipboard_representations only when
            // contentKind is missing; copy/paste and details still decode.
            guard let entry = metadataOnlyHistoryEntry(for: meta) else {
                bodyMetas.append(meta)
                continue
            }
            entriesByID[meta.id] = entry
            historyEntryCache.setObject(
                MacClippyHistoryEntryCacheBox(entry),
                forKey: cacheKey(for: meta),
                cost: historyEntryCacheCost(entry)
            )
        }
        return bodyMetas
    }

    private func batchHistoryEntries(
        for metas: [ClipboardItemMeta]
    ) throws -> [RecordID: MacClippyHistoryEntry]? {
        do {
            let bodies = try clipboardStore.bodies(for: metas.map(\.id))
            var entriesByID: [RecordID: MacClippyHistoryEntry] = [:]
            entriesByID.reserveCapacity(metas.count)
            for meta in metas {
                guard let body = bodies[meta.id] else { continue }
                guard meta.contentKind == nil || meta.contentKind == body.contentKind else {
                    recordCorruptStoredRecord(operation: "history_content_kind_mismatch")
                    continue
                }
                let entry = entry(for: meta, body: body)
                historyEntryCache.setObject(
                    MacClippyHistoryEntryCacheBox(entry),
                    forKey: cacheKey(for: meta),
                    cost: historyEntryCacheCost(entry)
                )
                entriesByID[meta.id] = entry
            }
            return entriesByID
        } catch {
            // A single damaged envelope should not hide healthy cards, but a
            // SQL/I/O/key failure must still reach the caller as a storage
            // error. The per-record retry below lets us isolate corruption.
            guard isCorruptStoredRecord(error) else { throw error }
            return nil
        }
    }

    // Metadata is part of the cache key, so a cached projection is safe to
    // reuse when validation is disabled, the persisted kind is absent, or the
    // cached body agrees with the persisted kind. A disagreement is the one
    // case where validation must force a fresh body read.
    private func reusableCachedHistoryEntry(
        for meta: ClipboardItemMeta,
        validateContentKind: Bool
    ) -> MacClippyHistoryEntry? {
        guard let cached = historyEntryCache.object(forKey: cacheKey(for: meta)) else {
            return nil
        }
        guard !validateContentKind
            || meta.contentKind == nil
            || cached.entry.contentKind == meta.contentKind else {
            return nil
        }
        return cached.entry
    }

    // P2b: build a SearchRecord for a meta. The predicate needs contentKind
    // only when the query has a type: clause; otherwise we avoid the body
    // read entirely so structured-only queries that filter on app/label/
    // has/before/after stay off the body-decryption path. When a kind is
    // needed, the body read reuses the same clipboardStore.body(for:) used
    // by entry(for:), so no new decryption surface is introduced.
    func searchRecord(
        for meta: ClipboardItemMeta,
        needsKind: Bool,
        knownKinds: [RecordID: MacClippyContentKind] = [:]
    ) throws -> MacClippySearchGrammar.SearchRecord? {
        let kind: MacClippyContentKind
        if needsKind {
            if let knownKind = knownKinds[meta.id] {
                kind = knownKind
            } else {
                do {
                    kind = try clipboardStore.body(for: meta.id).contentKind
                } catch {
                    if isCorruptStoredRecord(error) {
                        recordCorruptStoredRecord(operation: "structured_search_record")
                        return nil
                    }
                    throw error
                }
            }
        } else {
            kind = .text
        }
        return MacClippySearchGrammar.SearchRecord(
            meta: meta,
            contentKind: kind,
            sourceAppDisplayName: MacClippySourceAppSearch.preferredDisplayName(
                stored: meta.sourceAppDisplayName,
                resolved: MacClippySourceAppResolver.displayName(for: meta.sourceAppBundleID)
            )
        )
    }
}
