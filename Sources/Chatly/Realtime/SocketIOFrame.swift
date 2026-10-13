import Foundation

/// Engine.IO v4 + Socket.IO v5 text frames, encoded and decoded by hand.
///
/// ── Why this exists rather than a dependency ───────────────────────────────
///
/// `SocketTransport` used to be written against `Socket.IO-Client-Swift`
/// behind `#if canImport(SocketIO)`, and the package declares no such
/// dependency — so the guard was false in every build that has ever existed
/// and the whole realtime path was dead code. The package is deliberately
/// dependency-free (see the README and the published docs), and the visitor
/// socket needs a vanishingly small slice of the protocol: open a websocket,
/// send one CONNECT packet carrying `{ token, kind: "visitor" }`, answer the
/// server's pings, read `event` frames, and emit three event names. That is
/// this file. `URLSessionWebSocketTask` does the transport.
///
/// ── The grammar, which is all we implement ─────────────────────────────────
///
/// An Engine.IO v4 text frame is one ASCII digit of packet type followed by
/// its body:
///
/// ```
/// 0{"sid":"…","pingInterval":25000,…}   OPEN      (server → client)
/// 1                                     CLOSE
/// 2                                     PING      (server → client)
/// 3                                     PONG      (client → server)
/// 4<socket.io packet>                   MESSAGE
/// ```
///
/// A Socket.IO v5 packet (the body of a `4`) is again one digit, then an
/// optional `/namespace,`, then optional JSON. We only ever use the default
/// namespace, so nothing we SEND carries one, and anything we RECEIVE with
/// one is from a namespace we did not join and is ignored.
///
/// ```
/// 0{"sid":"…"}                 CONNECT        — the handshake succeeded
/// 4{"message":"Unauthorized"}  CONNECT_ERROR  — it did not
/// 2["event",{…}]               EVENT
/// 1                            DISCONNECT
/// ```
///
/// Binary attachments (`45-…`) are not implemented: this gateway publishes
/// JSON envelopes only, and a frame we cannot parse is reported as
/// ``ChatlySocketFrame/unsupported(_:)`` rather than guessed at.
public enum ChatlySocketFrame: Equatable {
    /// Engine.IO OPEN. `pingInterval` is milliseconds, when the server sent one.
    case open(pingIntervalMs: Int?)
    /// Engine.IO PING — must be answered with ``ChatlySocketCodec/pong``.
    case ping
    /// Engine.IO CLOSE.
    case close
    /// Socket.IO CONNECT, i.e. the auth payload was accepted.
    case connected(sid: String?)
    /// Socket.IO CONNECT_ERROR. The gateway's `Unauthorized` arrives here.
    case connectError(message: String?)
    /// Socket.IO EVENT. `payload` is the raw JSON of the first argument, if any.
    case event(name: String, payload: Data?)
    /// Socket.IO DISCONNECT.
    case disconnect
    /// Anything else, kept verbatim so a caller can log it.
    case unsupported(String)
}

/// Encoder/decoder for ``ChatlySocketFrame``. Pure functions — no I/O — so the
/// exact bytes the SDK puts on the wire are assertable in a unit test.
public enum ChatlySocketCodec {
    /// The reply to an Engine.IO PING. A client that never sends this is
    /// dropped by the server one `pingTimeout` later.
    public static let pong = "3"

    /// The Socket.IO CONNECT packet for the default namespace, carrying the
    /// handshake `auth` object.
    ///
    /// This is the frame the whole realtime defect lived in: `kind` is
    /// OPTIONAL in the gateway's `handshakeAuthSchema` and **defaults to
    /// `agent`**, so a handshake that omits it is verified RS256 against the
    /// platform's public key, a visitor's HS256 token fails that verify, and
    /// the connection is refused with a bare `Unauthorized`. The caller
    /// supplies the whole dictionary; ``SocketTransport`` is the one that
    /// always puts `kind: "visitor"` in it.
    public static func connect(auth: [String: Any]) throws -> String {
        let json = try JSONSerialization.data(withJSONObject: auth, options: [.sortedKeys])
        guard let text = String(data: json, encoding: .utf8) else {
            throw ChatlyError.notConfigured
        }
        return "40" + text
    }

    /// A Socket.IO EVENT packet: `42["<name>",<payload>]`.
    public static func event(name: String, payload: [String: Any]) throws -> String {
        let json = try JSONSerialization.data(withJSONObject: [name, payload], options: [.sortedKeys])
        guard let text = String(data: json, encoding: .utf8) else {
            throw ChatlyError.notConfigured
        }
        return "42" + text
    }

    /// Parse one inbound text frame.
    public static func decode(_ text: String) -> ChatlySocketFrame {
        guard let first = text.first else { return .unsupported(text) }
        let body = String(text.dropFirst())
        switch first {
        case "0":
            return .open(pingIntervalMs: Self.object(body)?["pingInterval"] as? Int)
        case "1":
            return .close
        case "2":
            return .ping
        case "3":
            // The server never pings us back, but a frame we sent being echoed
            // must not read as something else.
            return .unsupported(text)
        case "4":
            return decodeMessage(body)
        default:
            return .unsupported(text)
        }
    }

    // MARK: - Private

    private static func decodeMessage(_ body: String) -> ChatlySocketFrame {
        guard let kind = body.first else { return .unsupported("4" + body) }
        var rest = String(body.dropFirst())
        // Strip a namespace if one is present. We only ever join the default
        // namespace, so a packet addressed to another one is not ours.
        if rest.hasPrefix("/") {
            guard let comma = rest.firstIndex(of: ",") else {
                return .unsupported("4" + body)
            }
            let namespace = String(rest[rest.startIndex..<comma])
            if namespace != "/" {
                return .unsupported("4" + body)
            }
            rest = String(rest[rest.index(after: comma)...])
        }
        switch kind {
        case "0":
            return .connected(sid: Self.object(rest)?["sid"] as? String)
        case "1":
            return .disconnect
        case "2":
            return decodeEvent(rest, raw: "4" + body)
        case "4":
            return .connectError(message: Self.connectErrorMessage(rest))
        default:
            return .unsupported("4" + body)
        }
    }

    private static func decodeEvent(_ json: String, raw: String) -> ChatlySocketFrame {
        guard let data = json.data(using: .utf8),
              let array = (try? JSONSerialization.jsonObject(with: data)) as? [Any],
              let name = array.first as? String else {
            return .unsupported(raw)
        }
        guard array.count > 1 else { return .event(name: name, payload: nil) }
        // Re-serialised rather than handed over as `Any`: every consumer of
        // this decodes it with `JSONDecoder`, and round-tripping once here
        // beats each of them reaching into an untyped dictionary.
        let payload = try? JSONSerialization.data(withJSONObject: array[1])
        return .event(name: name, payload: payload)
    }

    /// Socket.IO sends a CONNECT_ERROR body as either `{"message":"…"}` or a
    /// bare string, depending on what the server's middleware threw.
    private static func connectErrorMessage(_ json: String) -> String? {
        if let obj = Self.object(json), let message = obj["message"] as? String {
            return message
        }
        guard let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? String
    }

    private static func object(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8), !data.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
