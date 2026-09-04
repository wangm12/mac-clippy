import XCTest

@testable import MacClippyCore

final class MacClippyExclusionAppPickerPolicyTests: XCTestCase {
    func testParseAndEncodeKeepUniqueLowercasedBundleIDs() {
        XCTAssertEqual(
            MacClippyExclusionAppPickerPolicy.parseStoredList(" com.Example.Editor, ,com.example.notes,com.example.editor "),
            ["com.example.editor", "com.example.notes"]
        )
        XCTAssertEqual(
            MacClippyExclusionAppPickerPolicy.encodeStoredList(["com.example.editor", "com.example.notes"]),
            "com.example.editor,com.example.notes"
        )
    }

    func testAddUsesTheBundleIdentifierInsteadOfATypedList() {
        let added = MacClippyExclusionAppPickerPolicy.add("com.example.Editor", to: "")
        XCTAssertEqual(added, "com.example.editor")
        XCTAssertEqual(
            MacClippyExclusionAppPickerPolicy.add("com.example.editor", to: added),
            "com.example.editor"
        )
        XCTAssertEqual(
            MacClippyExclusionAppPickerPolicy.add("  ", to: added),
            "com.example.editor"
        )
    }

    func testBuiltInPasswordManagersStayImplicitAndAreNotStored() {
        let stored = MacClippyExclusionAppPickerPolicy.add(
            "com.agilebits.onepassword7",
            to: "com.example.editor"
        )
        XCTAssertEqual(stored, "com.example.editor")
        XCTAssertEqual(
            MacClippyExclusionAppPickerPolicy.userBundleIDs(from: "com.example.editor,com.1password.1password"),
            ["com.example.editor"]
        )
    }

    func testRemoveOnlyDeletesUserChosenApps() {
        let stored = "com.example.editor,com.example.notes"
        XCTAssertEqual(
            MacClippyExclusionAppPickerPolicy.remove("com.example.editor", from: stored),
            "com.example.notes"
        )
        XCTAssertEqual(
            MacClippyExclusionAppPickerPolicy.remove("com.agilebits.onepassword7", from: stored),
            stored
        )
    }

    func testRowsShowDisplayNamesAndMarkBuiltInsAsNotRemovable() {
        let rows = MacClippyExclusionAppPickerPolicy.rows(
            stored: "com.example.editor",
            displayNames: ["com.example.editor": "Example Editor"]
        )
        XCTAssertEqual(
            rows.filter(\.canRemove).map(\.bundleID),
            ["com.example.editor"]
        )
        XCTAssertEqual(rows.first { $0.bundleID == "com.example.editor" }?.title, "Example Editor")
        XCTAssertEqual(
            rows.first { $0.bundleID == "com.example.missing" }?.title,
            nil
        )
        XCTAssertEqual(
            MacClippyExclusionAppPickerPolicy.displayTitle(
                bundleID: "com.example.missing",
                localizedName: nil
            ),
            "com.example.missing"
        )
        XCTAssertFalse(
            rows.contains { $0.bundleID == "com.agilebits.onepassword7" && $0.canRemove }
        )
        XCTAssertTrue(rows.contains { $0.bundleID == "com.agilebits.onepassword7" && !$0.canRemove })
    }
}
