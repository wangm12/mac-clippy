import Foundation
import GRDB

extension MacClippyClipboardStore {
    /// Changes whenever record metadata or payload ownership can change.
    /// Authentication trust-marker writes do not invalidate this revision.
    public func recordsRevision() throws -> Int64 {
        try database.queue.read { connection in
            guard let revision = try Int64.fetchOne(
                connection,
                sql: "SELECT value FROM macclippy_clipboard_state WHERE key = 'records_revision'"
            ) else { throw MacClippyStoreError.invalidStoredRecord }
            return revision
        }
    }

    static let recordsRevisionMigration = MacClippyDatabaseMigration(
        identifier: "013-clipboard-records-revision-and-scope-index"
    ) { database in
        try database.execute(sql: """
            CREATE INDEX IF NOT EXISTS idx_macclippy_records_content_kind_id
                ON clipboard_records(content_kind, id);
            CREATE TABLE macclippy_clipboard_state (
                key TEXT PRIMARY KEY NOT NULL,
                value INTEGER NOT NULL
            );
            INSERT INTO macclippy_clipboard_state(key, value) VALUES ('records_revision', 0);

            CREATE TRIGGER macclippy_records_revision_insert
            AFTER INSERT ON clipboard_records
            BEGIN
                UPDATE macclippy_clipboard_state SET value = value + 1 WHERE key = 'records_revision';
            END;
            CREATE TRIGGER macclippy_records_revision_delete
            AFTER DELETE ON clipboard_records
            BEGIN
                UPDATE macclippy_clipboard_state SET value = value + 1 WHERE key = 'records_revision';
            END;
            CREATE TRIGGER macclippy_records_revision_update
            AFTER UPDATE OF modified, content_kind, preview, source_app, source_app_name,
                custom_label, detected_type, ocr_text, envelope, primary_blob_id ON clipboard_records
            WHEN OLD.modified IS NOT NEW.modified OR OLD.content_kind IS NOT NEW.content_kind
                OR OLD.preview IS NOT NEW.preview OR OLD.source_app IS NOT NEW.source_app
                OR OLD.source_app_name IS NOT NEW.source_app_name OR OLD.custom_label IS NOT NEW.custom_label
                OR OLD.detected_type IS NOT NEW.detected_type OR OLD.ocr_text IS NOT NEW.ocr_text
                OR OLD.envelope IS NOT NEW.envelope OR OLD.primary_blob_id IS NOT NEW.primary_blob_id
            BEGIN
                UPDATE macclippy_clipboard_state SET value = value + 1 WHERE key = 'records_revision';
            END;

            CREATE TRIGGER macclippy_repr_revision_insert
            AFTER INSERT ON clipboard_representations
            BEGIN
                UPDATE macclippy_clipboard_state SET value = value + 1 WHERE key = 'records_revision';
            END;
            CREATE TRIGGER macclippy_repr_revision_delete
            AFTER DELETE ON clipboard_representations
            BEGIN
                UPDATE macclippy_clipboard_state SET value = value + 1 WHERE key = 'records_revision';
            END;
            CREATE TRIGGER macclippy_repr_revision_update
            AFTER UPDATE OF record_id, item_index, uti, payload, blob_id, payload_state ON clipboard_representations
            WHEN OLD.record_id IS NOT NEW.record_id OR OLD.item_index IS NOT NEW.item_index
                OR OLD.uti IS NOT NEW.uti OR OLD.payload IS NOT NEW.payload
                OR OLD.blob_id IS NOT NEW.blob_id OR OLD.payload_state IS NOT NEW.payload_state
            BEGIN
                UPDATE macclippy_clipboard_state SET value = value + 1 WHERE key = 'records_revision';
            END;
            """)
    }
}
