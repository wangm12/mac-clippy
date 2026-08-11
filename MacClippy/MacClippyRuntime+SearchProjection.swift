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
                representationUTIs: try clipboardStore.representationUTIs(for: id)
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
        representationUTIs: [String] = []
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
            segments.append(contentsOf: urls.flatMap { [$0.lastPathComponent, $0.path] })
        }
        segments.append(contentsOf: representationUTIs)
        let text = segments.joined(separator: "\n")
        return String(
            bytes: text.utf8.prefix(MacClippyRuntime.searchIndexTextByteLimit),
            encoding: .utf8
        ) ?? ""
    }

    // P2b: resolve FTS hits to history entries, preserving the existing
    // snippet-as-preview behavior for bare-term search. Shared by the
    // bare-only path so the structured integration does not change how a
    // pure bare query is rendered.
    func historyEntriesFromHits(
        _ hits: [SearchHit],
        shouldCancel: () -> Bool = { false }
    ) throws -> [MacClippyHistoryEntry] {
        let metas = try clipboardStore.metas(for: hits.map(\.id))
        let metasByID = Dictionary(uniqueKeysWithValues: metas.map { ($0.id, $0) })
        let entriesByID = try entries(for: metas, validateContentKind: true)
        var entries: [MacClippyHistoryEntry] = []
        entries.reserveCapacity(hits.count)
        for hit in hits {
            guard !shouldCancel() else { return [] }
            guard let meta = metasByID[hit.id], let entry = entriesByID[hit.id] else { continue }
            entries.append(MacClippyHistoryEntry(
                meta: meta,
                contentKind: entry.contentKind,
                preview: hit.snippet,
                fileURLs: entry.fileURLs,
                imageDimensions: entry.imageDimensions
            ))
        }
        return entries
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
        guard !uncachedMetas.isEmpty else { return entriesByID }
        let bodyMetas = metadataOnlyHistoryEntries(
            for: uncachedMetas,
            validateContentKind: validateContentKind,
            entriesByID: &entriesByID
        )
        guard !bodyMetas.isEmpty else { return entriesByID }
        if let batchEntries = try batchHistoryEntries(for: bodyMetas) {
            entriesByID.merge(batchEntries) { _, newer in newer }
            return entriesByID
        }

        for meta in bodyMetas {
            if let entry = try entry(for: meta) {
                entriesByID[meta.id] = entry
            }
        }
        return entriesByID
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
        validateContentKind: Bool,
        entriesByID: inout [RecordID: MacClippyHistoryEntry]
    ) -> [ClipboardItemMeta] {
        guard !validateContentKind else { return metas }
        var bodyMetas: [ClipboardItemMeta] = []
        bodyMetas.reserveCapacity(metas.count)
        for meta in metas {
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
        return MacClippySearchGrammar.SearchRecord(meta: meta, contentKind: kind)
    }
}
