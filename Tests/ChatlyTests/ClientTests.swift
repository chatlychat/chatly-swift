import XCTest
@testable import Chatly

final class ClientTests: XCTestCase {
    func testInitResponseDecodesFromCanonicalShape() throws {
        let json = """
        {
          "session": {
            "token": "vt_abc123",
            "contactId": "0190a5d0-7c3a-7000-8000-000000000001",
            "workspaceId": "0190a5d0-7c3a-7000-8000-000000000002",
            "brandId": "0190a5d0-7c3a-7000-8000-000000000003",
            "channelId": "0190a5d0-7c3a-7000-8000-000000000004"
          },
          "workspace": {
            "id": "0190a5d0-7c3a-7000-8000-000000000002",
            "name": "Acme Inc."
          },
          "branding": {
            "primaryColor": "#2563EB"
          }
        }
        """
        let data = Data(json.utf8)
        let response = try JSONDecoder().decode(InitResponse.self, from: data)
        XCTAssertEqual(response.session.token, "vt_abc123")
        XCTAssertEqual(response.workspace.name, "Acme Inc.")
    }

    func testConversationSummaryRoundTrips() throws {
        let json = """
        {
          "id": "c-1",
          "status": "open",
          "subject": null,
          "lastMessagePreview": "hi there",
          "lastMessageAt": "2026-05-28T12:00:00.000Z",
          "unreadContactCount": 2,
          "createdAt": "2026-05-28T11:59:00.000Z"
        }
        """
        let data = Data(json.utf8)
        let conv = try JSONDecoder().decode(ConversationSummary.self, from: data)
        XCTAssertEqual(conv.id, "c-1")
        XCTAssertEqual(conv.status, .open)
        XCTAssertEqual(conv.unreadContactCount, 2)
        XCTAssertNil(conv.subject)

        let reencoded = try JSONEncoder().encode(conv)
        let decoded = try JSONDecoder().decode(ConversationSummary.self, from: reencoded)
        XCTAssertEqual(decoded, conv)
    }

    func testMessageRowDecodesAllKinds() throws {
        let kinds: [(String, MessageRow.Kind)] = [
            ("text", .text),
            ("image", .image),
            ("file", .file),
            ("event", .event),
            ("internal_note", .internalNote),
        ]
        for (raw, expected) in kinds {
            let json = """
            {
              "id": "m-1",
              "authorType": "agent",
              "kind": "\(raw)",
              "body": "hi",
              "createdAt": "2026-05-28T12:00:00.000Z"
            }
            """
            let row = try JSONDecoder().decode(MessageRow.self, from: Data(json.utf8))
            XCTAssertEqual(row.kind, expected)
            XCTAssertEqual(row.authorType, .agent)
        }
    }

    func testKbArticleHandlesNullBodyHtml() throws {
        let json = """
        {
          "id": "kb-1",
          "slug": "getting-started",
          "title": "Getting started",
          "body": "# hi",
          "bodyHtml": null,
          "updatedAt": "2026-05-28T12:00:00.000Z"
        }
        """
        let article = try JSONDecoder().decode(KbArticle.self, from: Data(json.utf8))
        XCTAssertEqual(article.slug, "getting-started")
        XCTAssertNil(article.bodyHtml)
    }

    func testKbResultRoundTrips() throws {
        let result = KbResult(id: "kb-1", slug: "x", title: "X", excerpt: "An excerpt.")
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(KbResult.self, from: data)
        XCTAssertEqual(decoded, result)
    }

    func testWidgetIdentitySerialization() throws {
        let identity = WidgetIdentity(
            externalId: "u-42",
            email: "jamie@acme.io",
            name: "Jamie",
            userHash: "deadbeef",
            attributes: ["plan": AnyCodable("pro")]
        )
        let data = try JSONEncoder().encode(identity)
        let decoded = try JSONDecoder().decode(WidgetIdentity.self, from: data)
        XCTAssertEqual(decoded.externalId, "u-42")
        XCTAssertEqual(decoded.email, "jamie@acme.io")
        XCTAssertEqual(decoded.userHash, "deadbeef")
    }
}
