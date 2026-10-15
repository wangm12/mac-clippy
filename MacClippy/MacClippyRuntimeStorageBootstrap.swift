import Foundation

import MacClippyCore
import MacClippyPlatform

struct MacClippyRuntimeStorage {
    let paths: MacClippyPaths
    let databases: [MacClippyDatabase]
    let clipboardStore: ClipboardStore
    let searchStore: SearchStore
    let pinboardStore: PinboardStore
    let snippetStore: SnippetStore
    let snippetLookupSnapshot: MacClippySnippetLookupSnapshot
    let blobStore: BlobStore
    let thumbnailDiskCache: MacClippyThumbnailDiskCache

    init(paths: MacClippyPaths?, keychain: MacClippyKeychainBackend?) throws {
#if MACCLIPPY_E2E
        guard let paths, let keychain else {
            throw MacClippyE2EIsolationError.missingRuntimeDependencies
        }
        let resolvedPaths = paths
        let resolvedKeychain = keychain
#else
        let resolvedPaths = try paths ?? MacClippyPaths()
        let resolvedKeychain = keychain ?? MacClippyRuntime.defaultKeychain(paths: paths)
#endif
        self.paths = resolvedPaths
        let storageURLs = [
            resolvedPaths.clipboardDatabaseURL,
            resolvedPaths.searchDatabaseURL,
            resolvedPaths.pinboardDatabaseURL,
            resolvedPaths.snippetDatabaseURL
        ]
        let hasExistingStorage = storageURLs.contains {
            FileManager.default.fileExists(atPath: $0.path)
        }
        let key = try MacClippyDeviceKey(keychain: resolvedKeychain)
            .deviceKey(requireExistingStorage: hasExistingStorage)
        let deviceID = DeviceID.generate()
        let clipboardDatabase = try MacClippyDatabase(url: resolvedPaths.clipboardDatabaseURL)
        let searchDatabase = try MacClippyDatabase(url: resolvedPaths.searchDatabaseURL)
        let pinboardDatabase = try MacClippyDatabase(url: resolvedPaths.pinboardDatabaseURL)
        let snippetDatabase = try MacClippyDatabase(url: resolvedPaths.snippetDatabaseURL)
        databases = [clipboardDatabase, searchDatabase, pinboardDatabase, snippetDatabase]

        clipboardStore = try ClipboardStore(database: clipboardDatabase, deviceKey: key, deviceID: deviceID)
        searchStore = try SearchStore(database: searchDatabase)
        pinboardStore = try PinboardStore(database: pinboardDatabase, deviceKey: key)
        let snippetStore = try SnippetStore(database: snippetDatabase, deviceKey: key)
        self.snippetStore = snippetStore
        let snippetLookupSnapshot = MacClippySnippetLookupSnapshot()
        self.snippetLookupSnapshot = snippetLookupSnapshot
        snippetLookupSnapshot.replace(with: try snippetStore.list())
        blobStore = try BlobStore(rootURL: resolvedPaths.blobsURL, key: key)
        thumbnailDiskCache = MacClippyThumbnailDiskCache(
            directoryURL: resolvedPaths.thumbnailsURL,
            key: key
        )
    }
}
