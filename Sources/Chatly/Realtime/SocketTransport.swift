import Foundation

/// Connection lifecycle reported by ``SocketTransport``.
public enum SocketTransportState: Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting
    case errored(String)
}

/// The visitor's Socket.IO connection to the realtime gateway.
///
/// ── What this used to be, and why none of it worked ───────────────────────
///
/// Every line of the old implementation was behind `#if canImport(SocketIO)`
/// for a dependency the package has never declared, so `connect()` was a
/// no-op in every build that has ever existed. The protocol it described was
/// wrong too, in four independent ways — it opened `/realtime` (the gateway
/// serves `/socket.io`), it sent the long-lived `session.token` from
/// `/v1/widget/init` (the gateway does not accept that credential at all), it
/// put the token in `connectParams` and an `Authorization` header (the
/// gateway reads `socket.handshake.auth`), and it emitted a `subscribe`
/// packet naming a `visitor:{contactId}` channel (the visitor connection has
/// no `subscribe` handler; the gateway joins the room itself from the token's
/// `conversation_id` claim).
///
/// ── The contract this one speaks ───────────────────────────────────────────
///
/// ```
/// wss://<realtime host>/socket.io/?EIO=4&transport=websocket
/// auth: { token: <a token from POST /v1/widget/realtime/token>, kind: "visitor" }
/// inbound:  socket.on("event", envelope)
/// outbound: message.read | typing.start | typing.stop
/// ```
///
/// `kind` is the whole defect behind "mobile realtime does not work": it is
/// optional in the gateway's handshake schema and **defaults to `agent`**, so
/// omitting it routes the handshake to the RS256 agent verifier, which a
/// visitor's HS256 token fails.
///
/// ── Why there is no automatic reconnection ─────────────────────────────────
///
/// The browser widget passes socket.io a **callback** for `auth` rather than
/// an object, with the reason in a comment at
/// `apps/widget/src/realtime-client.ts:83-91`: a static auth object is
/// captured once and replayed verbatim on every reconnect, so a visitor whose
/// socket dropped after the realtime token's 1h lifetime reconnects with an
/// expired credential and is refused — silently, for the rest of the session.
///
/// There is no socket.io client here to hand a callback to, so this one does
/// the equivalent explicitly: **reconnection is hand-rolled, and every single
/// attempt calls ``mintToken`` again before it opens a socket.** A frozen
/// credential is never replayed because none is ever stored.
public final class SocketTransport {
    /// Produces a fresh realtime token. Invoked once per connection ATTEMPT —
    /// see the note on reconnection above.
    public typealias TokenProvider = () async throws -> String

    /// Last reported transport state.
    public private(set) var state: SocketTransportState = .disconnected

    /// Called on every decoded envelope. **Off the main thread.**
    public var onEnvelope: ((RealtimeEnvelope) -> Void)?
    /// Called on every state change. **Off the main thread.**
    public var onState: ((SocketTransportState) -> Void)?

    /// How many consecutive `Unauthorized` handshakes are retried before the
    /// transport gives up and stays `.errored`.
    ///
    /// A refusal of a token we minted seconds ago is a configuration fault (a
    /// channel with an origin allow-list, a gateway with no
    /// `VISITOR_REALTIME_JWT_SECRET`), not a credential that will age into
    /// working. Retrying it forever is a background loop on a visitor's
    /// battery. An ordinary socket close does NOT count against this — that
    /// is a network blip and the whole point of reconnecting.
    private static let maxAuthFailures = 5

    private let realtimeURL: URL
    private let mintToken: TokenProvider
    private let factory: ChatlyWebSocketFactory
    private let backoff: (Int) -> TimeInterval

    /// Serialises every mutation. The websocket's callbacks arrive on
    /// `URLSession`'s delegate queue and `connect()` runs on whatever task
    /// awaited it, so there is no single thread to pin this to.
    private let queue = DispatchQueue(label: "com.chatly.socket-transport")

    private var socket: ChatlyWebSocketChannel?
    /// Bumped on every open. A callback from a socket of an older generation
    /// belongs to a connection nobody owns any more and is dropped — this is
    /// the conversation-switch race.
    private var generation = 0
    private var wantsConnection = false
    private var attempt = 0
    private var authFailures = 0
    /// Set while a reconnect `Task` is in flight.
    ///
    /// A refused handshake produces TWO events — the `connect_error` packet
    /// and, right behind it, the socket closing — and without this both arms
    /// scheduled a retry, so every auth failure doubled the number of
    /// in-flight reconnect tasks.
    private var reconnectPending = false
    /// The auth object for the socket currently being opened, sent in reply to
    /// the Engine.IO OPEN frame.
    private var pendingAuth: [String: Any]?

    /// - Parameters:
    ///   - realtimeURL: the gateway origin, e.g. `https://realtime.chatlychat.com`.
    ///     `/socket.io/` and the Engine.IO query are appended internally.
    ///   - mintToken: called before every attempt. Must return a token from
    ///     `POST /v1/widget/realtime/token` — **not** the visitor session
    ///     token, which this gateway does not accept.
    ///   - factory: substitutable so a test can read the frames the SDK sends.
    ///   - backoff: seconds to wait before attempt *n* (0-based). Injected so
    ///     tests do not sleep.
    public init(realtimeURL: URL,
                mintToken: @escaping TokenProvider,
                factory: ChatlyWebSocketFactory = URLSessionWebSocketFactory(),
                backoff: @escaping (Int) -> TimeInterval = SocketTransport.defaultBackoff) {
        self.realtimeURL = realtimeURL
        self.mintToken = mintToken
        self.factory = factory
        self.backoff = backoff
    }

    /// 1s, 2s, 4s, 8s, then 10s forever — the widget's
    /// `reconnectionDelay`/`reconnectionDelayMax` pair.
    public static func defaultBackoff(_ attempt: Int) -> TimeInterval {
        return min(10, pow(2, Double(min(attempt, 10))))
    }

    /// Mints a token and opens the socket. Returns once the socket has been
    /// opened, not once the handshake has been accepted — watch ``onState``
    /// for that.
    public func connect() async {
        await open(resetAttempts: true)
    }

    /// Tears the socket down and stops reconnecting. Safe when already closed.
    public func disconnect() {
        queue.sync {
            wantsConnection = false
            generation += 1
            attempt = 0
            authFailures = 0
            reconnectPending = false
            pendingAuth = nil
            closeSocketLocked()
        }
        report(.disconnected)
    }

    /// Emits one event to the gateway. A no-op when the handshake has not
    /// completed: Socket.IO would buffer it in a client we do not have, and
    /// silently losing a `typing.start` is better than queueing reads against
    /// a conversation the visitor may have left.
    public func emit(_ name: String, payload: [String: Any]) {
        queue.sync {
            guard state == .connected, let socket = socket else { return }
            guard let frame = try? ChatlySocketCodec.event(name: name, payload: payload) else {
                return
            }
            socket.send(frame)
        }
    }

    /// Blocks until every queued state change has been applied. For tests
    /// only — production code watches ``onState``.
    internal func drain() {
        queue.sync {}
    }

    // MARK: - Connecting

    private func open(resetAttempts: Bool) async {
        let generationForThisAttempt: Int = queue.sync {
            wantsConnection = true
            if resetAttempts {
                attempt = 0
                authFailures = 0
            }
            generation += 1
            reconnectPending = false
            closeSocketLocked()
            return generation
        }
        report(.connecting)

        let token: String
        do {
            token = try await mintToken()
        } catch {
            // A mint failure is almost always the REST layer's — a 404 because
            // the conversation is not this visitor's, or a 403 from an origin
            // allow-list the native app cannot satisfy. Reported verbatim so
            // it is not mistaken for a socket problem.
            report(.errored("realtime token: \(error)"))
            scheduleReconnect(after: generationForThisAttempt, countsAsAuthFailure: false)
            return
        }

        queue.sync {
            guard wantsConnection, generationForThisAttempt == generation else { return }
            pendingAuth = ["token": token, "kind": "visitor"]
            socket = factory.open(
                url: Self.handshakeURL(realtimeURL),
                /*
                 * `guard let self` ONCE per callback, not `self?` twice.
                 *
                 * The two-`self?` form captures the weak var itself into the
                 * inner closure, which Swift 5's concurrency checking reports
                 * as "reference to captured var 'self' in concurrently-
                 * executing code; this is an error in Swift 6". Swift 6.3
                 * does not warn, so it is invisible locally and only the
                 * mirror CI (macos-14, an older toolchain) sees it.
                 *
                 * It is also a real difference in behaviour: with two
                 * optional chains, `self` can be non-nil when the callback
                 * fires and deallocated by the time the queue drains, so the
                 * inner call is silently dropped. Binding once holds it for
                 * the duration of the hop, which is what the handler assumes.
                 */
                onText: { [weak self] text in
                    guard let self else { return }
                    self.queue.async {
                        self.handleLocked(text: text, generation: generationForThisAttempt)
                    }
                },
                onClose: { [weak self] error in
                    guard let self else { return }
                    self.queue.async {
                        self.handleCloseLocked(error: error, generation: generationForThisAttempt)
                    }
                }
            )
        }
    }

    /// `https://host` → `wss://host/socket.io/?EIO=4&transport=websocket`.
    ///
    /// Any path on the base URL is preserved and `/socket.io/` appended to it,
    /// so a gateway behind a path-prefixed reverse proxy still resolves.
    internal static func handshakeURL(_ base: URL) -> URL {
        guard var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return base
        }
        switch comps.scheme {
        case "http", "ws":
            comps.scheme = "ws"
        default:
            comps.scheme = "wss"
        }
        var path = comps.path
        while path.hasSuffix("/") {
            path.removeLast()
        }
        comps.path = path + "/socket.io/"
        comps.queryItems = [
            URLQueryItem(name: "EIO", value: "4"),
            URLQueryItem(name: "transport", value: "websocket"),
        ]
        return comps.url ?? base
    }

    // MARK: - Frames (always on `queue`)

    private func handleLocked(text: String, generation: Int) {
        guard generation == self.generation else { return }
        switch ChatlySocketCodec.decode(text) {
        case .open:
            guard let auth = pendingAuth,
                  let frame = try? ChatlySocketCodec.connect(auth: auth) else { return }
            socket?.send(frame)
        case .connected:
            attempt = 0
            authFailures = 0
            setStateLocked(.connected)
        case .connectError(let message):
            // `Unauthorized` lands here. Re-mint and try again: the credential
            // is 1h-lived, so the overwhelmingly likely cause of a refusal
            // after a long background is that it expired.
            setStateLocked(.errored(message ?? "handshake refused"))
            closeSocketLocked()
            scheduleReconnectLocked(after: generation, countsAsAuthFailure: true)
        case .ping:
            socket?.send(ChatlySocketCodec.pong)
        case .close, .disconnect:
            closeSocketLocked()
            scheduleReconnectLocked(after: generation, countsAsAuthFailure: false)
        case .event(let name, let payload):
            guard name == "event", let payload = payload,
                  let envelope = try? JSONDecoder().decode(RealtimeEnvelope.self, from: payload) else {
                return
            }
            onEnvelope?(envelope)
        case .unsupported:
            break
        }
    }

    private func handleCloseLocked(error: Error?, generation: Int) {
        guard generation == self.generation else { return }
        socket = nil
        guard wantsConnection else {
            setStateLocked(.disconnected)
            return
        }
        // `reconnectPending` is what stops a refused handshake being counted
        // twice: the `connect_error` arm has already scheduled the retry and
        // this close is the same event arriving a frame later.
        _ = error
        scheduleReconnectLocked(after: generation, countsAsAuthFailure: false)
    }

    private func scheduleReconnect(after generation: Int, countsAsAuthFailure: Bool) {
        queue.sync { scheduleReconnectLocked(after: generation, countsAsAuthFailure: countsAsAuthFailure) }
    }

    private func scheduleReconnectLocked(after generation: Int, countsAsAuthFailure: Bool) {
        guard wantsConnection, generation == self.generation, !reconnectPending else { return }
        if countsAsAuthFailure {
            authFailures += 1
            if authFailures >= Self.maxAuthFailures {
                wantsConnection = false
                return
            }
        }
        let delay = backoff(attempt)
        attempt += 1
        reconnectPending = true
        setStateLocked(.reconnecting)
        Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard let self = self else { return }
            let stillWanted = self.queue.sync { self.wantsConnection && generation == self.generation }
            guard stillWanted else { return }
            await self.open(resetAttempts: false)
        }
    }

    // MARK: - State

    private func closeSocketLocked() {
        socket?.close()
        socket = nil
    }

    private func report(_ next: SocketTransportState) {
        queue.sync { setStateLocked(next) }
    }

    private func setStateLocked(_ next: SocketTransportState) {
        guard state != next else { return }
        state = next
        onState?(next)
    }
}
