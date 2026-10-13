import XCTest
@testable import Chatly

/// The visitor realtime handshake, asserted on what the SDK SENDS.
///
/// Every one of these failed before the fix in this commit, and the ways they
/// failed are the point:
///
/// - the handshake omitted `kind`, which is OPTIONAL in the gateway's
///   `handshakeAuthSchema` and **defaults to `agent`** — so the token was
///   verified RS256 against the platform's public key, a visitor's HS256 token
///   failed, and the gateway answered a bare `Unauthorized`;
/// - the token was the long-lived `session.token` from `/v1/widget/init`,
///   which the gateway does not accept at all;
/// - there was no mint call for the credential it does accept;
/// - and the whole transport was behind `#if canImport(SocketIO)` for a
///   dependency the package has never declared, so none of it ran.
final class RealtimeHandshakeTests: XCTestCase {

    private func makeTransport(
        tokens: [String],
        factory: FakeSocketFactory
    ) -> (SocketTransport, () -> Int) {
        let counter = Counter()
        let transport = SocketTransport(
            realtimeURL: URL(string: "https://realtime.test")!,
            mintToken: {
                let index = counter.next()
                return tokens[min(index, tokens.count - 1)]
            },
            factory: factory,
            backoff: { _ in 0 }
        )
        return (transport, { counter.value })
    }

    // MARK: - §4: the handshake carries `kind == "visitor"`

    func testHandshakeDeclaresTheVisitorKind() async {
        let factory = FakeSocketFactory()
        let (transport, _) = makeTransport(tokens: ["rt-1"], factory: factory)

        await transport.connect()
        await waitUntil("a socket to be opened") { factory.sockets.count == 1 }
        factory.sockets[0].deliver(FakeSocket.openFrame)
        await waitUntil("the CONNECT frame") { !factory.sockets[0].frames.isEmpty }

        let auth = handshakeAuth(factory.sockets[0].frames[0])
        XCTAssertEqual(auth?["kind"] as? String, "visitor",
                       "without `kind` the gateway verifies the token as an AGENT's RS256 one")
    }

    // MARK: - §4: the socket token is a MINTED realtime token

    func testSocketCarriesTheMintedTokenAndNotTheSessionToken() async {
        let factory = FakeSocketFactory()
        let (transport, _) = makeTransport(tokens: ["rt-minted"], factory: factory)

        await transport.connect()
        await waitUntil("a socket to be opened") { factory.sockets.count == 1 }
        factory.sockets[0].deliver(FakeSocket.openFrame)
        await waitUntil("the CONNECT frame") { !factory.sockets[0].frames.isEmpty }

        XCTAssertEqual(handshakeAuth(factory.sockets[0].frames[0])?["token"] as? String, "rt-minted")
    }

    /// The CONNECT packet is sent in reply to the Engine.IO OPEN frame, not
    /// before it. A client that fires it on socket-open races the server's
    /// handshake.
    func testConnectPacketWaitsForTheEngineOpenFrame() async {
        let factory = FakeSocketFactory()
        let (transport, _) = makeTransport(tokens: ["rt-1"], factory: factory)

        await transport.connect()
        await waitUntil("a socket to be opened") { factory.sockets.count == 1 }
        transport.drain()
        XCTAssertEqual(factory.sockets[0].frames, [],
                       "nothing may be sent before the server's OPEN frame")
    }

    // MARK: - §4: a second attempt re-reads the auth payload

    func testReconnectReMintsRatherThanReplayingTheFirstToken() async {
        let factory = FakeSocketFactory()
        let (transport, mintCount) = makeTransport(tokens: ["rt-1", "rt-2"], factory: factory)

        await transport.connect()
        await waitUntil("the first socket") { factory.sockets.count == 1 }
        factory.sockets[0].deliver(FakeSocket.openFrame)
        await waitUntil("the first CONNECT frame") { !factory.sockets[0].frames.isEmpty }
        factory.sockets[0].deliver(#"40{"sid":"s1"}"#)
        await waitUntil("the connected state") { transport.state == .connected }

        // The socket dies after the token's 1h lifetime would have elapsed.
        factory.sockets[0].drop()
        await waitUntil("a second socket") { factory.sockets.count == 2 }
        factory.sockets[1].deliver(FakeSocket.openFrame)
        await waitUntil("the second CONNECT frame") { !factory.sockets[1].frames.isEmpty }

        XCTAssertEqual(mintCount(), 2, "every ATTEMPT must mint, not just the first")
        XCTAssertEqual(handshakeAuth(factory.sockets[1].frames[0])?["token"] as? String, "rt-2",
                       "a frozen credential replayed on reconnect is the silent-death bug")
        XCTAssertEqual(handshakeAuth(factory.sockets[1].frames[0])?["kind"] as? String, "visitor")
    }

    /// A refused handshake is retried with a fresh credential — the common
    /// cause of `Unauthorized` after a long background is simply expiry.
    func testRefusedHandshakeRetriesWithANewToken() async {
        let factory = FakeSocketFactory()
        let (transport, _) = makeTransport(tokens: ["rt-1", "rt-2"], factory: factory)

        await transport.connect()
        await waitUntil("the first socket") { factory.sockets.count == 1 }
        factory.sockets[0].deliver(FakeSocket.openFrame)
        await waitUntil("the first CONNECT frame") { !factory.sockets[0].frames.isEmpty }
        factory.sockets[0].deliver(#"44{"message":"Unauthorized"}"#)

        await waitUntil("a second socket") { factory.sockets.count == 2 }
        factory.sockets[1].deliver(FakeSocket.openFrame)
        await waitUntil("the second CONNECT frame") { !factory.sockets[1].frames.isEmpty }
        XCTAssertEqual(handshakeAuth(factory.sockets[1].frames[0])?["token"] as? String, "rt-2")
    }

    /// …but not forever. A token minted seconds ago being refused is a
    /// configuration fault, and a background loop on a visitor's battery is
    /// not a recovery strategy.
    func testGivesUpAfterRepeatedAuthFailures() async {
        let factory = FakeSocketFactory()
        let (transport, _) = makeTransport(tokens: ["rt-bad"], factory: factory)

        await transport.connect()
        for attempt in 0..<8 {
            // Five attempts is the cap; stop feeding refusals once it is hit.
            guard factory.sockets.count == attempt + 1 else { break }
            let socket = factory.sockets[attempt]
            socket.deliver(FakeSocket.openFrame)
            await waitUntil("CONNECT frame \(attempt)") { !socket.frames.isEmpty }
            socket.deliver(#"44{"message":"Unauthorized"}"#)
            if attempt < 4 {
                await waitUntil("socket \(attempt + 2)") { factory.sockets.count == attempt + 2 }
            }
        }
        transport.drain()
        XCTAssertEqual(factory.sockets.count, 5, "capped at maxAuthFailures")
    }

    func testDisconnectStopsReconnecting() async {
        let factory = FakeSocketFactory()
        let (transport, _) = makeTransport(tokens: ["rt-1"], factory: factory)

        await transport.connect()
        await waitUntil("the first socket") { factory.sockets.count == 1 }
        transport.disconnect()
        factory.sockets[0].drop()
        transport.drain()
        // Same reason as `waitUntil`: `run(until:)` is noasync and this test is async.
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(factory.sockets.count, 1)
        XCTAssertEqual(transport.state, .disconnected)
    }

    // MARK: - Frames

    func testAnswersTheServersPing() async {
        let factory = FakeSocketFactory()
        let (transport, _) = makeTransport(tokens: ["rt-1"], factory: factory)

        await transport.connect()
        await waitUntil("the first socket") { factory.sockets.count == 1 }
        let socket = factory.sockets[0]
        socket.deliver(FakeSocket.openFrame)
        await waitUntil("the CONNECT frame") { socket.frames.count == 1 }
        socket.deliver("2")
        await waitUntil("the PONG") { socket.frames.count == 2 }
        XCTAssertEqual(socket.frames[1], "3",
                       "a client that never pongs is dropped one pingTimeout later")
    }

    func testDecodesAnEnvelopeFromTheEventChannel() async {
        let factory = FakeSocketFactory()
        let (transport, _) = makeTransport(tokens: ["rt-1"], factory: factory)
        let received = Box<RealtimeEnvelope>()
        transport.onEnvelope = { received.value = $0 }

        await transport.connect()
        await waitUntil("the first socket") { factory.sockets.count == 1 }
        let socket = factory.sockets[0]
        socket.deliver(FakeSocket.openFrame)
        await waitUntil("the CONNECT frame") { socket.frames.count == 1 }
        socket.deliver(#"40{"sid":"s1"}"#)
        socket.deliver(
            #"42["event",{"v":1,"type":"message.created","id":"0190a5d0-7c3a-7000-8000-000000000001","#
            + #""ts":1716835200000,"workspace_id":"0190a5d0-7c3a-7000-8000-000000000002","#
            + #""payload":{"body":"hi"}}]"#
        )
        await waitUntil("the envelope") { received.value != nil }
        XCTAssertEqual(received.value?.type, .messageCreated)
    }

    /// Only `event`. The gateway publishes everything on that one channel, and
    /// `envelope` — the name the old transport listened for — is not a name it
    /// has ever emitted.
    func testIgnoresAnEventNameTheGatewayNeverEmits() async {
        let factory = FakeSocketFactory()
        let (transport, _) = makeTransport(tokens: ["rt-1"], factory: factory)
        let received = Box<RealtimeEnvelope>()
        transport.onEnvelope = { received.value = $0 }

        await transport.connect()
        await waitUntil("the first socket") { factory.sockets.count == 1 }
        let socket = factory.sockets[0]
        socket.deliver(FakeSocket.openFrame)
        await waitUntil("the CONNECT frame") { socket.frames.count == 1 }
        socket.deliver(#"40{"sid":"s1"}"#)
        socket.deliver(#"42["envelope",{"v":1,"type":"message.created","id":"a","ts":1,"workspace_id":"w","payload":{}}]"#)
        transport.drain()
        XCTAssertNil(received.value)
    }

    func testEmitIsADropBeforeTheHandshakeCompletes() async {
        let factory = FakeSocketFactory()
        let (transport, _) = makeTransport(tokens: ["rt-1"], factory: factory)

        await transport.connect()
        await waitUntil("the first socket") { factory.sockets.count == 1 }
        let socket = factory.sockets[0]
        socket.deliver(FakeSocket.openFrame)
        await waitUntil("the CONNECT frame") { socket.frames.count == 1 }

        transport.emit("message.read", payload: ["conversationId": "c-1"])
        transport.drain()
        XCTAssertEqual(socket.frames.count, 1, "nothing may be queued against an unconnected socket")

        socket.deliver(#"40{"sid":"s1"}"#)
        await waitUntil("the connected state") { transport.state == .connected }
        transport.emit("message.read", payload: ["conversationId": "c-1"])
        await waitUntil("the emitted read") { socket.frames.count == 2 }
        XCTAssertEqual(emittedEvent(socket.frames[1])?.name, "message.read")
    }

    // MARK: - URL

    /// `/socket.io`, not `/realtime`. The old transport passed
    /// `.path("/realtime")`, which is not a path this gateway serves.
    func testHandshakeURLIsTheGatewaysOwn() {
        XCTAssertEqual(
            SocketTransport.handshakeURL(URL(string: "https://realtime.chatlychat.com")!)
                .absoluteString,
            "wss://realtime.chatlychat.com/socket.io/?EIO=4&transport=websocket"
        )
        XCTAssertEqual(
            SocketTransport.handshakeURL(URL(string: "http://localhost:3002/")!).absoluteString,
            "ws://localhost:3002/socket.io/?EIO=4&transport=websocket"
        )
        // A path prefix on the base URL is kept, for a gateway behind a proxy.
        XCTAssertEqual(
            SocketTransport.handshakeURL(URL(string: "https://example.test/rt")!).absoluteString,
            "wss://example.test/rt/socket.io/?EIO=4&transport=websocket"
        )
    }
}

// MARK: - Helpers

/// `mintToken` is `@Sendable`-ish and called from a detached task, so a plain
/// captured `var` is not safe to count with.
final class Counter {
    private let lock = NSLock()
    private var count = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let current = count
        count += 1
        return current
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

final class Box<T> {
    private let lock = NSLock()
    private var stored: T?

    var value: T? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }
}
