import Foundation

/// Indexes that keep `type:` / `app:` / `has:ocr` off a full `clipboard_records`
/// meta scan. `content_kind` already ships in `003-clipboard-query-indexes`.
public enum MacClippyStructuredSearchIndexPolicy {
    public static let contentKindIndex = "idx_macclippy_records_content_kind"
    public static let sourceAppIndex = "idx_macclippy_records_source_app"
    public static let sourceAppNameIndex = "idx_macclippy_records_source_app_name"
    public static let hasOCRIndex = "idx_macclippy_records_has_ocr"

    public static let requiredIndexNames = [
        contentKindIndex,
        sourceAppIndex,
        sourceAppNameIndex,
        hasOCRIndex
    ]

    public static let createMissingIndexesSQL = """
        CREATE INDEX IF NOT EXISTS \(sourceAppIndex)
            ON clipboard_records(source_app);
        CREATE INDEX IF NOT EXISTS \(hasOCRIndex)
            ON clipboard_records(id)
            WHERE ocr_text IS NOT NULL AND trim(ocr_text) != '';
        """

    public static let createSourceAppNameIndexSQL = """
        CREATE INDEX IF NOT EXISTS \(sourceAppNameIndex)
            ON clipboard_records(source_app_name);
        """
}
