import CryptoKit
import Foundation

@testable import MacClippyCore

enum MacClippyBackupProcessCrashFixtures {
    typealias Support = MacClippyBackupProcessCrashSupport

    private struct DatabaseSet {
        let clipboard: MacClippyDatabase
        let search: MacClippyDatabase
        let pinboards: MacClippyDatabase
        let snippets: MacClippyDatabase

        var all: [MacClippyDatabase] { [clipboard, search, pinboards, snippets] }
    }

    private struct GenerationValues {
        let name: String
        let textBody: String
        let imageDocument: String
        let imageBlobID: String
        let imagePayload: Data
        let representationBlobID: String
        let representationPayload: Data
        let pinboardName: String
        let snippetName: String
        let snippetBody: String
        let snippetTrigger: String
    }

    static func makeSnapshot(at snapshotURL: URL, key: SymmetricKey) throws -> Support.GenerationExpectation {
        let databases = try openInMemoryDatabases()
        defer { closeDatabases(databases.all) }
        let sourceBlobsURL = snapshotURL.deletingLastPathComponent()
            .appendingPathComponent("snapshot-source-blobs", isDirectory: true)
        let expectation = try seedStores(
            values: generationValues(named: Support.newGenerationName),
            databases: databases,
            blobsURL: sourceBlobsURL,
            key: key,
            markerPayloads: [:]
        )
        _ = try MacClippyBackup.create(
            sources: [
                MacClippyBackupSource(name: "clipboard", database: databases.clipboard),
                MacClippyBackupSource(name: "search", database: databases.search),
                MacClippyBackupSource(name: "pinboards", database: databases.pinboards),
                MacClippyBackupSource(name: "snippets", database: databases.snippets)
            ],
            blobsURL: sourceBlobsURL,
            deviceKey: key,
            at: snapshotURL
        )
        return expectation
    }

    static func seedOldRoot(
        at liveRootURL: URL,
        key: SymmetricKey
    ) throws -> Support.GenerationExpectation {
        let markerPayloads = Dictionary(
            uniqueKeysWithValues: MacClippyBackup.liveComponents.map { ($0, Support.oldPayload(for: $0)) }
        )
        try seedEncryptedMarkers(markerPayloads, at: liveRootURL, key: key)
        let databases = try openDatabases(
            at: liveRootURL.appendingPathComponent("databases", isDirectory: true)
        )
        defer { closeDatabases(databases.all) }
        return try seedStores(
            values: generationValues(named: Support.oldGenerationName),
            databases: databases,
            blobsURL: liveRootURL.appendingPathComponent("blobs", isDirectory: true),
            key: key,
            markerPayloads: markerPayloads
        )
    }

    private static func seedEncryptedMarkers(_ payloads: [String: Data], at rootURL: URL, key: SymmetricKey) throws {
        for (component, payload) in payloads {
            let componentURL = rootURL.appendingPathComponent(component, isDirectory: true)
            try FileManager.default.createDirectory(at: componentURL, withIntermediateDirectories: true)
            let envelope = try MacClippyCipher.seal(payload, with: key)
            try envelope.combined.write(
                to: componentURL.appendingPathComponent(Support.oldPayloadName),
                options: .atomic
            )
        }
    }

    private static func generationValues(named name: String) -> GenerationValues {
        GenerationValues(
            name: name,
            textBody: "phase5 \(name) authenticated clipboard body",
            imageDocument: "phase5 \(name) searchable image attachment",
            imageBlobID: "phase5-\(name)-image-payload",
            imagePayload: Data("phase5 \(name) owned image bytes".utf8),
            representationBlobID: "phase5-\(name)-representation-payload",
            representationPayload: Data("phase5 \(name) owned PNG representation".utf8),
            pinboardName: "phase5 \(name) pinboard",
            snippetName: "phase5 \(name) snippet",
            snippetBody: "phase5 \(name) authenticated snippet body",
            snippetTrigger: "p5\(name)"
        )
    }

    private static func openDatabases(at rootURL: URL) throws -> DatabaseSet {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        return DatabaseSet(
            clipboard: try MacClippyDatabase(url: rootURL.appendingPathComponent("clipboard.sqlite")),
            search: try MacClippyDatabase(url: rootURL.appendingPathComponent("search.sqlite")),
            pinboards: try MacClippyDatabase(url: rootURL.appendingPathComponent("pinboards.sqlite")),
            snippets: try MacClippyDatabase(url: rootURL.appendingPathComponent("snippets.sqlite"))
        )
    }

    private static func openInMemoryDatabases() throws -> DatabaseSet {
        DatabaseSet(
            clipboard: try MacClippyDatabase(inMemory: true),
            search: try MacClippyDatabase(inMemory: true),
            pinboards: try MacClippyDatabase(inMemory: true),
            snippets: try MacClippyDatabase(inMemory: true)
        )
    }

    private static func seedStores(
        values: GenerationValues,
        databases: DatabaseSet,
        blobsURL: URL,
        key: SymmetricKey,
        markerPayloads: [String: Data]
    ) throws -> Support.GenerationExpectation {
        let clipboard = try ClipboardStore(database: databases.clipboard, deviceKey: key)
        let search = try SearchStore(database: databases.search)
        let pinboards = try PinboardStore(database: databases.pinboards, deviceKey: key)
        let snippets = try SnippetStore(database: databases.snippets, deviceKey: key)
        let blobs = try BlobStore(rootURL: blobsURL, key: key)

        let textMeta = try seedTextRecord(values, clipboard: clipboard, search: search)
        let imageMeta = try seedImageRecord(values, clipboard: clipboard, search: search, blobs: blobs)
        let pinboard = try pinboards.create(name: values.pinboardName, color: "phase5")
        try pinboards.addItem(textMeta.id, to: pinboard.id)
        let snippet = try snippets.create(
            name: values.snippetName,
            body: values.snippetBody,
            trigger: values.snippetTrigger,
            folder: "Phase 5 Fixtures"
        )

        return Support.GenerationExpectation(
            name: values.name,
            textRecordID: textMeta.id,
            imageRecordID: imageMeta.id,
            pinboardID: pinboard.id,
            snippetID: snippet.id,
            textBody: values.textBody,
            imageDocument: values.imageDocument,
            imageBlobID: values.imageBlobID,
            imagePayload: values.imagePayload,
            representationBlobID: values.representationBlobID,
            representationPayload: values.representationPayload,
            pinboardName: values.pinboardName,
            snippetName: values.snippetName,
            snippetBody: values.snippetBody,
            snippetTrigger: values.snippetTrigger,
            markerPayloads: markerPayloads
        )
    }

    private static func seedTextRecord(
        _ values: GenerationValues,
        clipboard: ClipboardStore,
        search: SearchStore
    ) throws -> ClipboardItemMeta {
        let textMeta = try clipboard.append(
            .text(values.textBody),
            representations: [
                MacClippyClipboardRepresentation(
                    uti: Support.textRepresentationUTI,
                    payloadBytes: Data(values.textBody.utf8)
                )
            ]
        )
        try search.insert(id: textMeta.id, text: values.textBody)
        return textMeta
    }

    private static func seedImageRecord(
        _ values: GenerationValues,
        clipboard: ClipboardStore,
        search: SearchStore,
        blobs: BlobStore
    ) throws -> ClipboardItemMeta {
        _ = try blobs.write(values.imagePayload, id: values.imageBlobID)
        _ = try blobs.write(values.representationPayload, id: values.representationBlobID)
        let imageMeta = try clipboard.append(
            .image(blobID: values.imageBlobID, width: 4, height: 3),
            representations: [
                MacClippyClipboardRepresentation(
                    uti: Support.imageRepresentationUTI,
                    payloadBytes: nil,
                    blobID: values.representationBlobID
                )
            ]
        )
        try search.insert(id: imageMeta.id, text: values.imageDocument)
        return imageMeta
    }

    private static func closeDatabases(_ databases: [MacClippyDatabase]) {
        databases.forEach { try? $0.queue.close() }
    }
}
