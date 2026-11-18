import Foundation
import GRDB

extension MacClippyClipboardStore {
    public static var migrations: [MacClippyDatabaseMigration] {
        [
            MacClippyDatabaseMigration(identifier: "001-clipboard-core") { database in
                try database.execute(sql: MacClippyClipboardStore.schemaSQL)
            },
            // P0 no-filter capture: a side table that retains every external
            // NSPasteboard representation (UTI + encrypted Data, or BlobStore id)
            // for a clipboard record. The legacy single-payload envelope column is
            // preserved so existing local records continue to decode and existing
            // call sites keep working.
            MacClippyDatabaseMigration(identifier: "002-clipboard-representations") { database in
                try database.execute(sql: """
                    CREATE TABLE IF NOT EXISTS clipboard_representations (
                        record_id TEXT NOT NULL,
                        sort_order INTEGER NOT NULL,
                        uti TEXT NOT NULL,
                        payload BLOB,
                        blob_id TEXT,
                        payload_state TEXT NOT NULL DEFAULT 'present',
                        PRIMARY KEY(record_id, uti),
                        FOREIGN KEY(record_id) REFERENCES clipboard_records(id) ON DELETE CASCADE
                    );
                    CREATE INDEX IF NOT EXISTS idx_macclippy_repr_blob
                        ON clipboard_representations(blob_id);
                """)
            },
            // Structured `type:` queries and image-only maintenance passes use
            // the persisted discriminator instead of decrypting every envelope.
            MacClippyDatabaseMigration(identifier: "003-clipboard-query-indexes") { database in
                try database.execute(sql: """
                    CREATE INDEX IF NOT EXISTS idx_macclippy_records_content_kind
                        ON clipboard_records(content_kind);
                """)
            },
            // Cross-database deletion is intentionally journaled in the clipboard
            // database, which is already protected by the runtime store lock.
            // FTS/pinboard cleanup and external blob deletion can then be retried
            // after a force quit without guessing whether the parent row existed.
            MacClippyDatabaseMigration(identifier: "004-deletion-journal") { database in
                try database.execute(sql: """
                    CREATE TABLE IF NOT EXISTS clipboard_deletion_operations (
                        operation_id TEXT PRIMARY KEY NOT NULL,
                        created INTEGER NOT NULL
                    );
                    CREATE TABLE IF NOT EXISTS clipboard_deletion_journal (
                        operation_id TEXT NOT NULL,
                        record_id TEXT NOT NULL,
                        blob_id TEXT NOT NULL,
                        PRIMARY KEY(operation_id, record_id, blob_id),
                        FOREIGN KEY(operation_id)
                            REFERENCES clipboard_deletion_operations(operation_id)
                            ON DELETE CASCADE
                    );
                    CREATE INDEX IF NOT EXISTS idx_macclippy_deletion_record
                        ON clipboard_deletion_journal(record_id);
                """)
            },
            // Keep record IDs independently of Blob IDs. A text-only deletion has
            // no representation/blob row, but its cross-database cleanup still
            // needs to be replayable after a force quit.
            MacClippyDatabaseMigration(identifier: "005-deletion-records") { database in
                try database.execute(sql: """
                    CREATE TABLE IF NOT EXISTS clipboard_deletion_records (
                        operation_id TEXT NOT NULL,
                        record_id TEXT NOT NULL,
                        PRIMARY KEY(operation_id, record_id),
                        FOREIGN KEY(operation_id)
                            REFERENCES clipboard_deletion_operations(operation_id)
                            ON DELETE CASCADE
                    );
                    CREATE INDEX IF NOT EXISTS idx_macclippy_deletion_records_record
                        ON clipboard_deletion_records(record_id);
                    INSERT OR IGNORE INTO clipboard_deletion_records(operation_id, record_id)
                        SELECT DISTINCT operation_id, record_id
                        FROM clipboard_deletion_journal;
                """)
            },
            // Capture-time dedup looks up an identical payload by plaintext hash
            // so a recopy can bump frequency instead of sealing another envelope.
            MacClippyDatabaseMigration(identifier: "006-capture-content-hash") { database in
                try database.execute(sql: """
                    ALTER TABLE clipboard_records ADD COLUMN content_hash TEXT;
                    CREATE UNIQUE INDEX IF NOT EXISTS idx_macclippy_records_content_hash
                        ON clipboard_records(content_hash)
                        WHERE content_hash IS NOT NULL;
                """)
            },
            // Structured `app:` and `has:ocr` filters were still scanning every
            // meta row. `type:` already uses idx_macclippy_records_content_kind.
            MacClippyDatabaseMigration(identifier: "007-structured-search-indexes") { database in
                try database.execute(sql: MacClippyStructuredSearchIndexPolicy.createMissingIndexesSQL)
            },
            MacClippyDatabaseMigration(identifier: "008-search-and-storage-metadata") { database in
                try database.execute(sql: """
                    ALTER TABLE clipboard_records ADD COLUMN source_app_name TEXT;
                    ALTER TABLE clipboard_records ADD COLUMN primary_blob_id TEXT;
                """)
                try database.execute(sql: MacClippyStructuredSearchIndexPolicy.createSourceAppNameIndexSQL)
            },
            // Body-image and spilled-representation references are stored in
            // normalized columns/rows. The verification marker is invalidated by
            // SQL triggers whenever one of those authenticated sources changes;
            // bounded backfill authenticates the row before it can inform a delete.
            MacClippyDatabaseMigration(identifier: "009-verified-attachment-references") { database in
                try database.execute(sql: """
                    ALTER TABLE clipboard_records
                        ADD COLUMN blob_references_verified INTEGER NOT NULL DEFAULT 0;
                    CREATE INDEX IF NOT EXISTS idx_macclippy_records_primary_blob
                        ON clipboard_records(primary_blob_id);
                    CREATE INDEX IF NOT EXISTS idx_macclippy_records_blob_refs_unverified
                        ON clipboard_records(id) WHERE blob_references_verified = 0;

                    CREATE TRIGGER IF NOT EXISTS macclippy_records_blob_refs_invalidate
                    AFTER UPDATE OF envelope, primary_blob_id ON clipboard_records
                    BEGIN
                        UPDATE clipboard_records
                        SET blob_references_verified = 0
                        WHERE id = NEW.id;
                    END;

                    CREATE TRIGGER IF NOT EXISTS macclippy_repr_blob_refs_invalidate_insert
                    AFTER INSERT ON clipboard_representations
                    BEGIN
                        UPDATE clipboard_records
                        SET blob_references_verified = 0
                        WHERE id = NEW.record_id;
                    END;

                    CREATE TRIGGER IF NOT EXISTS macclippy_repr_blob_refs_invalidate_update
                    AFTER UPDATE ON clipboard_representations
                    BEGIN
                        UPDATE clipboard_records
                        SET blob_references_verified = 0
                        WHERE id IN (OLD.record_id, NEW.record_id);
                    END;

                    CREATE TRIGGER IF NOT EXISTS macclippy_repr_blob_refs_invalidate_delete
                    AFTER DELETE ON clipboard_representations
                    BEGIN
                        UPDATE clipboard_records
                        SET blob_references_verified = 0
                        WHERE id = OLD.record_id;
                    END;
                """)
            },
            // The body envelope does not contain the full advertised pasteboard
            // representation set. Keep an authenticated roster beside it so a
            // missing or rewritten spilled row cannot become a false orphan.
            MacClippyDatabaseMigration(identifier: "010-authenticated-representation-roster") { database in
                try database.execute(sql: """
                    ALTER TABLE clipboard_records ADD COLUMN representation_refs_auth BLOB;
                    DROP INDEX IF EXISTS idx_macclippy_records_blob_refs_unverified;
                    CREATE INDEX idx_macclippy_records_blob_refs_unverified
                        ON clipboard_records(id) WHERE blob_references_verified != 1;

                    CREATE TRIGGER IF NOT EXISTS macclippy_blob_refs_verified_insert_guard
                    BEFORE INSERT ON clipboard_records
                    WHEN NEW.blob_references_verified NOT IN (0, 1)
                    BEGIN
                        SELECT RAISE(ABORT, 'invalid attachment reference verification marker');
                    END;

                    CREATE TRIGGER IF NOT EXISTS macclippy_blob_refs_verified_update_guard
                    BEFORE UPDATE OF blob_references_verified ON clipboard_records
                    WHEN NEW.blob_references_verified NOT IN (0, 1)
                    BEGIN
                        SELECT RAISE(ABORT, 'invalid attachment reference verification marker');
                    END;

                    CREATE TRIGGER IF NOT EXISTS macclippy_roster_auth_invalidate
                    AFTER UPDATE OF representation_refs_auth ON clipboard_records
                    BEGIN
                        UPDATE clipboard_records
                        SET blob_references_verified = 0
                        WHERE id = NEW.id;
                    END;
                """)
            },
            // The normalized content-kind discriminator participates in
            // authenticated body validation. Mutating it must invalidate the
            // destructive attachment-reference trust marker as well.
            MacClippyDatabaseMigration(identifier: "011-content-kind-reference-invalidation") { database in
                try database.execute(sql: "DROP TRIGGER IF EXISTS macclippy_records_blob_refs_invalidate")
                try database.execute(sql: """
                    CREATE TRIGGER macclippy_records_blob_refs_invalidate
                    AFTER UPDATE OF envelope, primary_blob_id, content_kind ON clipboard_records
                    BEGIN
                        UPDATE clipboard_records
                        SET blob_references_verified = 0
                        WHERE id = NEW.id;
                    END;
                """)
            },
            // Preserve native NSPasteboard item boundaries. The legacy table
            // keyed each record only by UTI, which collapsed repeated UTIs
            // across different items into one row. Existing rows migrate to
            // item zero without changing their authenticated roster semantics.
            MacClippyDatabaseMigration(identifier: "012-pasteboard-item-identity") { database in
                try database.execute(sql: "DROP TRIGGER IF EXISTS macclippy_repr_blob_refs_invalidate_insert")
                try database.execute(sql: "DROP TRIGGER IF EXISTS macclippy_repr_blob_refs_invalidate_update")
                try database.execute(sql: "DROP TRIGGER IF EXISTS macclippy_repr_blob_refs_invalidate_delete")
                try database.execute(sql: "DROP INDEX IF EXISTS idx_macclippy_repr_blob")
                try database.execute(
                    sql: "ALTER TABLE clipboard_representations RENAME TO clipboard_representations_legacy"
                )
                try database.execute(sql: """
                    CREATE TABLE clipboard_representations (
                        record_id TEXT NOT NULL,
                        item_index INTEGER NOT NULL CHECK(item_index >= 0),
                        sort_order INTEGER NOT NULL,
                        uti TEXT NOT NULL,
                        payload BLOB,
                        blob_id TEXT,
                        payload_state TEXT NOT NULL DEFAULT 'present',
                        PRIMARY KEY(record_id, item_index, uti),
                        FOREIGN KEY(record_id) REFERENCES clipboard_records(id) ON DELETE CASCADE
                    );
                    INSERT INTO clipboard_representations
                        (record_id, item_index, sort_order, uti, payload, blob_id, payload_state)
                    SELECT record_id, 0, sort_order, uti, payload, blob_id, payload_state
                    FROM clipboard_representations_legacy;
                    DROP TABLE clipboard_representations_legacy;
                    CREATE INDEX idx_macclippy_repr_blob ON clipboard_representations(blob_id);

                    CREATE TRIGGER macclippy_repr_blob_refs_invalidate_insert
                    AFTER INSERT ON clipboard_representations
                    BEGIN
                        UPDATE clipboard_records SET blob_references_verified = 0 WHERE id = NEW.record_id;
                    END;

                    CREATE TRIGGER macclippy_repr_blob_refs_invalidate_update
                    AFTER UPDATE ON clipboard_representations
                    BEGIN
                        UPDATE clipboard_records SET blob_references_verified = 0
                        WHERE id IN (OLD.record_id, NEW.record_id);
                    END;

                    CREATE TRIGGER macclippy_repr_blob_refs_invalidate_delete
                    AFTER DELETE ON clipboard_representations
                    BEGIN
                        UPDATE clipboard_records SET blob_references_verified = 0 WHERE id = OLD.record_id;
                    END;
                """)
            },
            MacClippyClipboardStore.recordsRevisionMigration
        ]
    }

    private static var schemaSQL: String { """
        CREATE TABLE IF NOT EXISTS clipboard_records (
            id TEXT PRIMARY KEY NOT NULL,
            created INTEGER NOT NULL,
            modified INTEGER NOT NULL,
            device_id TEXT NOT NULL,
            lamport INTEGER NOT NULL,
            kind TEXT NOT NULL,
            content_kind TEXT NOT NULL,
            preview TEXT NOT NULL,
            source_app TEXT,
            frequency INTEGER NOT NULL DEFAULT 0,
            last_accessed INTEGER,
            custom_label TEXT,
            detected_type TEXT,
            ocr_text TEXT,
            envelope BLOB NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_macclippy_records_modified
            ON clipboard_records(modified DESC, lamport DESC, id DESC);
        CREATE INDEX IF NOT EXISTS idx_macclippy_records_frequency
            ON clipboard_records(frequency DESC, modified DESC);
        CREATE TABLE IF NOT EXISTS macclippy_lamport_clock (
            scope TEXT PRIMARY KEY NOT NULL,
            value INTEGER NOT NULL
        );
        INSERT OR IGNORE INTO macclippy_lamport_clock(scope, value) VALUES ('clipboard', 0);
    """ }
}
