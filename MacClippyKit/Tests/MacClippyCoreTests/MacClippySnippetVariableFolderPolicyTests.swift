import CryptoKit
import XCTest

@testable import MacClippyCore

final class MacClippySnippetVariableFolderPolicyTests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testKnownVariablesExpandAndUnknownTokensStay() throws {
        let now = try XCTUnwrap(
            utc.date(from: DateComponents(year: 2026, month: 9, day: 3, hour: 19, minute: 5))
        )
        let context = MacClippySnippetVariableContext(
            now: now,
            calendar: utc,
            clipboard: "pasted text"
        )

        XCTAssertEqual(
            MacClippySnippetVariablePolicy.expand(
                "Sent {{date}} {{time}}\n{{clipboard}} {{unknown}} {{date",
                context: context
            ),
            "Sent 2026-09-03 19:05\npasted text {{unknown}} {{date"
        )
    }

    func testFolderNamesNormalizeAndGroupTogether() {
        XCTAssertEqual(MacClippySnippetFolderPolicy.normalized(" Work / Email "), "Work/Email")
        XCTAssertNil(MacClippySnippetFolderPolicy.normalized(" ../secret "))
        XCTAssertNil(MacClippySnippetFolderPolicy.normalized("  "))

        let email = RecordID.generate()
        let other = RecordID.generate()
        let loose = RecordID.generate()
        let groups = MacClippySnippetFolderPolicy.groups(
            from: [
                (id: email, folder: " Work / Email "),
                (id: other, folder: "Work/Email"),
                (id: loose, folder: nil)
            ]
        )

        XCTAssertEqual(groups.map(\.folder), ["Work/Email", nil])
        XCTAssertEqual(groups[0].snippetIDs, [email, other])
        XCTAssertEqual(groups[1].snippetIDs, [loose])
    }

    func testStorePersistsNormalizedFolderAndLeavesItOnNameUpdate() throws {
        let store = try SnippetStore(
            database: MacClippyDatabase(inMemory: true),
            deviceKey: SymmetricKey(data: Data(repeating: 11, count: 32))
        )
        let created = try store.create(
            name: "Email",
            body: "Sent {{date}}",
            folder: " Work / Email "
        )
        XCTAssertEqual(created.folder, "Work/Email")
        XCTAssertEqual(try store.fetch(id: created.id).folder, "Work/Email")

        try store.update(id: created.id, name: "Email reply", body: "Thanks", trigger: nil)
        XCTAssertEqual(try store.fetch(id: created.id).folder, "Work/Email")
    }
}
