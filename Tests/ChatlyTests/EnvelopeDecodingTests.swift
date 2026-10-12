import XCTest
@testable import Chatly

final class EnvelopeDecodingTests: XCTestCase {
    func testDecodesCanonicalEnvelope() throws {
        let json = """
        {
          "v": 1,
          "type": "message.created",
          "id": "0190a5d0-7c3a-7000-8000-000000000001",
          "ts": 1716835200000,
          "workspace_id": "0190a5d0-7c3a-7000-8000-000000000002",
          "payload": {
            "id": "0190a5d0-7c3a-7000-8000-000000000003",
            "conversationId": "0190a5d0-7c3a-7000-8000-000000000004",
            "authorType": "agent",
            "authorId": "agent-1",
            "body": "Hello there",
            "attachments": [],
            "createdAt": "2026-05-28T12:00:00.000Z"
          }
        }
        """
        let data = Data(json.utf8)
        let envelope = try JSONDecoder().decode(RealtimeEnvelope.self, from: data)
        XCTAssertEqual(envelope.v, 1)
        XCTAssertEqual(envelope.type, .messageCreated)
        XCTAssertEqual(envelope.workspaceId, "0190a5d0-7c3a-7000-8000-000000000002")
        XCTAssertEqual(envelope.ts, 1_716_835_200_000)
    }

    func testRoundTripsThroughEncodeDecode() throws {
        let original = RealtimeEnvelope(
            type: .typingStart,
            id: "0190a5d0-7c3a-7000-8000-00000000aaaa",
            ts: 1_716_835_200_001,
            workspaceId: "0190a5d0-7c3a-7000-8000-00000000bbbb",
            payload: AnyCodable([
                "conversationId": "0190a5d0-7c3a-7000-8000-00000000cccc",
                "actorType": "contact",
                "actorId": "visitor-7",
            ] as [String: Any])
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RealtimeEnvelope.self, from: data)
        XCTAssertEqual(decoded.type, .typingStart)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.ts, original.ts)
        XCTAssertEqual(decoded.workspaceId, original.workspaceId)
    }

    func testUnknownEventTypeFallsBackToUnknownCase() throws {
        let json = """
        {
          "v": 1,
          "type": "future.event.kind",
          "id": "0190a5d0-7c3a-7000-8000-00000000dddd",
          "ts": 1716835200000,
          "workspace_id": "0190a5d0-7c3a-7000-8000-00000000eeee",
          "payload": null
        }
        """
        let data = Data(json.utf8)
        let envelope = try JSONDecoder().decode(RealtimeEnvelope.self, from: data)
        if case .unknown(let raw) = envelope.type {
            XCTAssertEqual(raw, "future.event.kind")
        } else {
            XCTFail("expected unknown event")
        }
    }

    func testTypedPayloadProjection() throws {
        struct MessagePayload: Codable, Equatable {
            let id: String
            let body: String
        }
        let envelope = RealtimeEnvelope(
            type: .messageCreated,
            id: "0190a5d0-7c3a-7000-8000-00000000ffff",
            ts: 1_716_835_200_002,
            workspaceId: "0190a5d0-7c3a-7000-8000-000000001111",
            payload: AnyCodable([
                "id": "msg-1",
                "body": "hi",
            ] as [String: Any])
        )
        let typed = envelope.decodePayload(as: MessagePayload.self)
        XCTAssertEqual(typed, MessagePayload(id: "msg-1", body: "hi"))
    }
}
