import XCTest
@testable import Chatly

/// The Engine.IO v4 / Socket.IO v5 frame grammar, both directions.
///
/// Hand-written because the package is dependency-free, which means this file
/// is the only thing standing between the SDK and a protocol error that looks
/// exactly like a network problem.
final class SocketIOFrameTests: XCTestCase {

    // MARK: - Encoding

    func testConnectFrameIsPacketFortyPlusTheAuthObject() throws {
        let frame = try ChatlySocketCodec.connect(auth: ["token": "t", "kind": "visitor"])
        XCTAssertEqual(frame, #"40{"kind":"visitor","token":"t"}"#)
    }

    func testEventFrameIsPacketFortyTwoPlusANameAndPayloadArray() throws {
        let frame = try ChatlySocketCodec.event(name: "message.read", payload: ["a": 1])
        XCTAssertEqual(frame, #"42["message.read",{"a":1}]"#)
    }

    func testPongIsASingleThree() {
        XCTAssertEqual(ChatlySocketCodec.pong, "3")
    }

    // MARK: - Decoding

    func testDecodesTheEngineOpenFrameAndItsPingInterval() {
        let frame = ChatlySocketCodec.decode(#"0{"sid":"abc","pingInterval":25000,"pingTimeout":20000}"#)
        XCTAssertEqual(frame, .open(pingIntervalMs: 25_000))
    }

    func testDecodesPingAndClose() {
        XCTAssertEqual(ChatlySocketCodec.decode("2"), .ping)
        XCTAssertEqual(ChatlySocketCodec.decode("1"), .close)
    }

    func testDecodesTheSocketConnectAck() {
        XCTAssertEqual(ChatlySocketCodec.decode(#"40{"sid":"xyz"}"#), .connected(sid: "xyz"))
        // Some servers answer with no body at all.
        XCTAssertEqual(ChatlySocketCodec.decode("40"), .connected(sid: nil))
    }

    /// The gateway's refusal. `next(err)` in its handshake middleware produces
    /// `{"message":"Unauthorized"}`, and that string is the only thing it says
    /// about which of the two visitor credentials it was unhappy about.
    func testDecodesConnectErrorInBothShapesTheServerUses() {
        XCTAssertEqual(ChatlySocketCodec.decode(#"44{"message":"Unauthorized"}"#),
                       .connectError(message: "Unauthorized"))
        XCTAssertEqual(ChatlySocketCodec.decode(#"44"Unauthorized""#),
                       .connectError(message: "Unauthorized"))
    }

    func testDecodesAnEventWithItsPayloadAsRawJSON() throws {
        let frame = ChatlySocketCodec.decode(#"42["event",{"v":1}]"#)
        guard case .event(let name, let payload) = frame else {
            return XCTFail("expected an event, got \(frame)")
        }
        XCTAssertEqual(name, "event")
        let decoded = try XCTUnwrap(payload)
        XCTAssertEqual(String(data: decoded, encoding: .utf8), #"{"v":1}"#)
    }

    func testDecodesAnEventWithNoPayload() {
        XCTAssertEqual(ChatlySocketCodec.decode(#"42["replay.completed"]"#),
                       .event(name: "replay.completed", payload: nil))
    }

    /// The default namespace may be written explicitly; anything else is a
    /// namespace this client never joined.
    func testAcceptsAnExplicitDefaultNamespaceAndIgnoresOthers() {
        XCTAssertEqual(ChatlySocketCodec.decode(#"40/,{"sid":"xyz"}"#), .connected(sid: "xyz"))
        guard case .unsupported = ChatlySocketCodec.decode(#"42/admin,["event",{}]"#) else {
            return XCTFail("a foreign namespace must not be read as ours")
        }
    }

    /// Binary attachments (`45-…`) and anything else unparseable are reported
    /// rather than guessed at — this gateway publishes JSON only, so a frame
    /// we cannot read is news.
    func testReportsRatherThanGuessesAtWhatItCannotParse() {
        guard case .unsupported(let raw) = ChatlySocketCodec.decode("45-2[\"x\"]") else {
            return XCTFail("expected unsupported")
        }
        XCTAssertEqual(raw, "45-2[\"x\"]")
        guard case .unsupported = ChatlySocketCodec.decode("") else {
            return XCTFail("expected unsupported for an empty frame")
        }
        guard case .unsupported = ChatlySocketCodec.decode(#"42not-json"#) else {
            return XCTFail("expected unsupported for a malformed event")
        }
    }
}
