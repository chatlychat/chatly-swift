import XCTest

@testable import Chatly

/// The two restated server enums, against what the server actually sends.
///
/// ## What was wrong
///
/// `ConversationSummary.Status` listed four of the server's five states.
/// `merged` was missing, and — unlike every other mobile SDK, which fall back
/// to a default on an unrecognised value — this one used the synthesized
/// `Decodable`, so an unknown raw value **throws**. It throws while decoding
/// the array, so one merged thread made `listConversations()` fail entirely:
/// the visitor's Messages tab went empty and the error named a coding path
/// rather than a cause.
///
/// `MessageRow.Kind` was wrong in both directions — four cases the server has
/// never sent, and `system_event` missing — and `init(from:)` swallows an
/// unknown kind as `.text`, which is what kept it invisible.
///
/// ## Why these tests decode real JSON
///
/// `ClientTests.testMessageRowDecodesAllKinds` asserted the SDK agreed with
/// its own enum: the list of raw strings it looped over was the list of cases
/// that enum happened to declare, so it passed for five years' worth of wrong
/// values. The server's definitions are TypeScript in `packages/shared`,
/// which Swift cannot import and which does not exist in this package's
/// published mirror — the only CI it has. So the server side of the
/// comparison is the wire strings below, copied from
/// `packages/shared/src/schemas/conversation.ts` and
/// `packages/shared/src/message-kinds/index.ts`, and each is asserted against
/// the real decoder on a real response body.
final class WireVocabularyTests: XCTestCase {
    /// `conversationStatusSchema`, verbatim.
    private static let statusWire: [(String, ConversationSummary.Status)] = [
        ("open", .open),
        ("pending", .pending),
        ("snoozed", .snoozed),
        ("closed", .closed),
        ("merged", .merged),
    ]

    private func listJSON(status: String) -> Data {
        Data("""
        {
          "conversations": [
            {
              "id": "c-1",
              "status": "\(status)",
              "subject": null,
              "lastMessagePreview": "hi",
              "lastMessageAt": "2026-05-28T12:00:00.000Z",
              "unreadContactCount": 0,
              "createdAt": "2026-05-28T11:00:00.000Z"
            }
          ]
        }
        """.utf8)
    }

    func testEveryServerStatusDecodes() throws {
        // The floor: five, so a list that loses entries fails here rather
        // than passing over a shorter loop.
        XCTAssertGreaterThanOrEqual(Self.statusWire.count, 5)
        for (raw, expected) in Self.statusWire {
            let page = try JSONDecoder().decode(
                ConversationListResponse.self, from: listJSON(status: raw))
            XCTAssertEqual(page.conversations.first?.status, expected, raw)
        }
    }

    /// The regression, at the level it actually bit: the whole response.
    func testAMergedThreadDoesNotTakeTheWholeListDown() throws {
        let page = try JSONDecoder().decode(
            ConversationListResponse.self, from: listJSON(status: "merged"))
        XCTAssertEqual(page.conversations.count, 1)
        XCTAssertEqual(page.conversations.first?.status, .merged)
    }

    /// And the same guarantee for a state that does not exist yet, which is
    /// the half `merged` alone would not have fixed.
    func testAnUnknownStatusDecodesRatherThanThrowing() throws {
        let page = try JSONDecoder().decode(
            ConversationListResponse.self, from: listJSON(status: "a_state_from_2027"))
        XCTAssertEqual(page.conversations.first?.status, .unknown)
    }

    func testIsResumableIsFalseForTheStatesThatAreNot() {
        XCTAssertFalse(ConversationSummary.Status.merged.isResumable)
        XCTAssertFalse(ConversationSummary.Status.closed.isResumable)
        XCTAssertFalse(ConversationSummary.Status.unknown.isResumable)
        XCTAssertTrue(ConversationSummary.Status.open.isResumable)
        XCTAssertTrue(ConversationSummary.Status.pending.isResumable)
        XCTAssertTrue(ConversationSummary.Status.snoozed.isResumable)
    }

    func testStatusEnumHoldsExactlyTheServerSetPlusUnknown() {
        let declared = Set(ConversationSummary.Status.allCases.map(\.rawValue))
        XCTAssertEqual(declared, Set(Self.statusWire.map { $0.0 }).union(["unknown"]))
    }

    /// `note` is in the `message_kind` enum and must never reach a visitor,
    /// so a case for it would be a dead branch — the mirror of the bug above.
    func testKindDoesNotOfferNote() {
        XCTAssertFalse(MessageRow.Kind.allCases.map(\.rawValue).contains("note"))
    }

    func testTheFourInventedKindsAreGone() {
        let declared = Set(MessageRow.Kind.allCases.map(\.rawValue))
        for dead in ["image", "file", "event", "internal_note"] {
            XCTAssertFalse(declared.contains(dead), dead)
        }
    }
}
