import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Where the SDK keeps the visitor session between launches.
///
/// Abstracted so the request path can replace a refused token in PERSISTENT
/// storage without reaching for the Keychain directly — and so tests can
/// assert that it really was replaced. ``KeychainSessionStorage`` is the
/// production implementation and the default.
public protocol ChatlySessionStorage: AnyObject {
    func read(_ key: String) -> String?
    func write(_ value: String, forKey key: String)
    func delete(_ key: String)
}

/// Default ``ChatlySessionStorage``, backed by ``ChatlyKeychain``.
public final class KeychainSessionStorage: ChatlySessionStorage {
    public init() {}
    public func read(_ key: String) -> String? { ChatlyKeychain.get(account: key) }
    public func write(_ value: String, forKey key: String) { ChatlyKeychain.set(value, account: key) }
    public func delete(_ key: String) { ChatlyKeychain.delete(account: key) }
}

/// Chatly iOS SDK (Swift).
///
/// Identify visitors, fire CDP events, and open the chat widget in a sheet.
/// Requires Swift 5.7+ and iOS 14+.
public final class Chatly {
    public struct Config {
        public let channelPublicId: String
        public let baseURL: URL
        public let appURL: URL
        /// Where the Socket.IO gateway lives, when you need to override it.
        ///
        /// `nil` — the default — means "use what `POST /v1/widget/init`
        /// reports", which is the per-region `realtimeUrl` the server already
        /// sends. Only a deployment whose gateway is somewhere neither this
        /// nor the `api.` → `realtime.` convention finds needs to set it. Same
        /// precedence as the browser widget's `resolveRealtimeUrl`.
        public let realtimeURL: URL?
        /// Production by default.
        ///
        /// These were `api.chatly.example` and `app.chatly.example` — reserved
        /// RFC 2606 domains that resolve nowhere, so every call failed for
        /// anyone who did not know to override them. The same defect shipped in
        /// the JS and Node SDKs (`api.livechat.local`) and was reported by a
        /// customer who integrated from the docs alone.
        public init(channelPublicId: String,
                    baseURL: URL = URL(string: "https://api.chatlychat.com")!,
                    appURL: URL = URL(string: "https://app.chatlychat.com")!,
                    realtimeURL: URL? = nil) {
            self.channelPublicId = channelPublicId
            self.baseURL = baseURL
            self.appURL = appURL
            self.realtimeURL = realtimeURL
        }
    }

    public static let shared = Chatly()

    internal var config: Config?
    /// Injectable so tests can drive the request path through a `URLProtocol`
    /// stub. Production always uses `URLSession.shared`.
    internal var urlSession: URLSession = .shared
    /// Injectable for the same reason; see ``ChatlySessionStorage``.
    internal var storage: ChatlySessionStorage = KeychainSessionStorage()
    /// Injectable so a test can read the handshake frames the SDK sends.
    /// Production always opens a real `URLSessionWebSocketTask`.
    internal var webSocketFactory: ChatlyWebSocketFactory = URLSessionWebSocketFactory()
    /// Injectable so a test's reconnect does not sleep.
    internal var realtimeBackoff: (Int) -> TimeInterval = SocketTransport.defaultBackoff

    /// Every realtime envelope for the connected conversation. **Delivered off
    /// the main thread** — bounce before touching UIKit.
    public var onRealtimeEvent: ((RealtimeEnvelope) -> Void)?

    internal var realtime: SocketTransport?
    /// The conversation the open socket is scoped to. The realtime token names
    /// ONE conversation, so switching means mint-and-reconnect rather than
    /// reusing the socket — a reused socket keeps delivering the old
    /// conversation's events.
    internal var realtimeConversationId: String?

    /// The thread ``send(_:)`` continues, and the default for
    /// ``connectRealtime(conversationId:)``. Set by `startConversation`,
    /// `replyTo` and `listConversations`.
    internal var currentConversationId: String?
    /// From the last `init`. `message.read` is refused by the gateway unless
    /// `readerId` equals the token's own contact, so the client has to know it.
    internal var sessionContactId: String?
    /// `init`'s own `realtimeUrl`. See ``Config/realtimeURL`` for precedence.
    internal var sessionRealtimeURL: String?

    /// The signed visitor session credential. Sent in the JSON body of every
    /// widget call — the widget surface has never read an `Authorization`
    /// header.
    private var visitorToken: String?

    /// The identity to replay after the server refuses a stale session.
    ///
    /// Kept because the visitor token is no longer the external id — it is an
    /// opaque signed credential now — so when the server refuses a stale token
    /// this is the only way the SDK can re-assert who the host app said this
    /// person was, without waiting for the app to call `identify` again.
    /// Conversation history hangs off the contact, so replaying it brings all
    /// of it back.
    private var rememberedIdentity: WidgetIdentity?

    /// `internal` rather than `private` so tests can build an isolated client
    /// instead of mutating the process-wide ``shared`` singleton.
    internal init() {}

    public func configure(_ config: Config) {
        self.config = config
        let restored = storage.read(Chatly.tokenKey(config.channelPublicId))
        self.visitorToken = restored
        self.rememberedIdentity = Chatly.decodeIdentity(
            storage.read(Chatly.identityKey(config.channelPublicId))
        )
    }

    // MARK: - Session

    /// Open (or resume) this device's visitor session.
    ///
    /// Persists the returned token, and remembers `identity` — but only once
    /// the server has ACCEPTED it, and only when it carries a `userHash`.
    /// Remembering a rejected hash would replay it on every later request and
    /// turn one 403 into a permanently broken SDK; remembering an unverifiable
    /// claim could only ever turn one refusal into two, because a channel with
    /// identity verification enabled refuses a claim without a hash and a
    /// channel without it still accepts a legacy token.
    @discardableResult
    public func initSession(identity: WidgetIdentity? = nil) async throws -> InitResponse {
        let (parsed, _) = try await initSessionReturningRaw(identity: identity)
        return parsed
    }

    /// Forget this device's session entirely.
    ///
    /// Drops the remembered identity too: after a logout, a stale-session
    /// recovery must NOT quietly re-identify as the person who just signed out.
    public func reset() {
        disconnectRealtime()
        currentConversationId = nil
        sessionContactId = nil
        dropToken()
        rememberedIdentity = nil
        if let cfg = config {
            storage.delete(Chatly.identityKey(cfg.channelPublicId))
        }
    }

    @discardableResult
    public func identify(externalId: String?,
                         email: String? = nil,
                         name: String? = nil,
                         userHash: String? = nil,
                         attributes: [String: Any] = [:]) async throws -> [String: Any] {
        /*
         * Built when ANY field was supplied, not only when `externalId` was.
         *
         * This was `if let externalId { … }`, so an app calling
         * `identify(externalId: user.id, email: user.email)` with a nil `id`
         * sent no `identity` key whatsoever and the email, name, `userHash`
         * and attributes were all thrown away client-side. The server has
         * accepted an email-only identity deliberately since
         * `widgetInitSchema`'s `externalId` became optional — and the reason
         * recorded there is that every SDK advertises `identify({ email })`.
         *
         * `nil` only when the caller supplied nothing at all, which is a
         * no-op identify and should stay one rather than send an empty
         * object the server would have to interpret.
         */
        let hasAnything =
            externalId != nil || email != nil || name != nil || userHash != nil
                || !attributes.isEmpty
        let identity: WidgetIdentity? = hasAnything
            ? WidgetIdentity(
                externalId: externalId,
                email: email,
                name: name,
                userHash: userHash,
                attributes: attributes.isEmpty ? nil : attributes.mapValues { AnyCodable($0) }
            )
            : nil
        // No `/v1/widget/identify` route has ever existed — identity goes to
        // `init`, which is also where verified-identity hashing is checked.
        let (_, raw) = try await initSessionReturningRaw(identity: identity)
        return raw
    }

    @discardableResult
    public func track(_ name: String, properties: [String: Any] = [:]) async throws -> [String: Any] {
        return try await post("/v1/widget/events", body: ["name": name, "properties": properties])
    }

    /// Send a message as this visitor, opening a thread if there is not one.
    ///
    /// This posted `{ body, kind }` to `POST /v1/widget/messages` and nothing
    /// else, and that endpoint's schema (`widgetReplySchema`) REQUIRES
    /// `conversationId` — so every call 400'd, and there was no method on this
    /// client that would have given you an id to pass. `kind` was dropped by
    /// zod on the way in, which is why the failure was about the missing id
    /// rather than the surplus key.
    ///
    /// It now continues ``currentConversationId`` when there is one and starts
    /// a conversation when there is not, which is what a chat SDK's `send`
    /// means on a device that has exactly one visitor.
    @discardableResult
    public func send(_ body: String) async throws -> [String: Any] {
        if let conversationId = currentConversationId {
            let message = try await replyTo(conversationId: conversationId, body: body)
            return Chatly.rawObject(message)
        }
        let started = try await startConversation(body: body)
        return Chatly.rawObject(started)
    }

    public func registerPushToken(_ deviceToken: Data) async throws {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        // Visitor push registers through the widget surface, not the agent one.
        _ = try await post("/v1/widget/push/register", body: ["platform": "apns", "token": hex])
    }

    // MARK: - Transport

    @discardableResult
    internal func post(_ path: String, body: [String: Any]) async throws -> [String: Any] {
        let data = try await postData(path, body: body)
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
    }

    private func initSessionReturningRaw(
        identity: WidgetIdentity?
    ) async throws -> (InitResponse, [String: Any]) {
        var body: [String: Any] = [
            "locale": Locale.current.identifier,
            "timezone": TimeZone.current.identifier,
            "page": ["url": "app://ios", "title": "native"],
        ]
        if let identity {
            body["identity"] = try Chatly.jsonObject(identity)
        }
        let data = try await postData("/v1/widget/init", body: body)
        let parsed = try JSONDecoder().decode(InitResponse.self, from: data)
        store(token: parsed.session.token)
        sessionContactId = parsed.session.contactId
        sessionRealtimeURL = parsed.realtimeUrl
        if let identity, identity.userHash != nil {
            remember(identity: identity)
        }
        let raw = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
        return (parsed, raw)
    }

    /// The one choke point every widget call goes through.
    ///
    /// - Parameters:
    ///   - idempotencyKey: minted once per logical call and REUSED on the
    ///     stale-session replay below, so a replayed write coalesces
    ///     server-side instead of double-sending.
    ///   - isRetry: set only by ``recoverSession(_:body:idempotencyKey:)``, to
    ///     bound recovery to a single attempt. A second refusal is a real
    ///     error and is thrown.
    @discardableResult
    internal func postData(_ path: String,
                          body: [String: Any],
                          idempotencyKey: String? = nil,
                          isRetry: Bool = false) async throws -> Data {
        guard let cfg = config else { throw ChatlyError.notConfigured }
        let key = idempotencyKey ?? UUID().uuidString

        // The session fields belong to the transport, not to each call site:
        // owning them here is what lets the replay below carry a fresh token
        // without every caller re-threading it.
        var payload = body
        payload["publicId"] = cfg.channelPublicId
        if let visitorToken {
            payload["visitorToken"] = visitorToken
        }

        var req = URLRequest(url: cfg.baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "Idempotency-Key")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, resp) = try await urlSession.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            if status == 403, !isRetry, Chatly.isStaleSession(data) {
                return try await recoverSession(path, body: body, idempotencyKey: key)
            }
            throw ChatlyError.http(status: status)
        }
        return data
    }

    /// The server refused the token in this device's storage. Get a new one
    /// and replay the call, once.
    ///
    /// This is what a mid-session mobile visitor hits on the deploy that
    /// closes the identity-verification bypass: the token in the Keychain
    /// predates signed visitor sessions, and on a channel with verification
    /// enabled it is refused rather than honoured. Without this the app
    /// surfaces one failed call and only self-heals on the NEXT launch,
    /// because the dead token stays on disk. Handled here rather than
    /// surfaced, because from the visitor's side nothing has gone wrong.
    private func recoverSession(_ path: String,
                                body: [String: Any],
                                idempotencyKey: String) async throws -> Data {
        var retry = body
        let identity = rememberedIdentity
        dropToken()
        if path == "/v1/widget/init" {
            // Re-boot in place: the dead token is already gone from the
            // transport, so keep whatever identity the caller asked for and
            // fall back to the remembered one.
            if retry["identity"] == nil, let identity {
                retry["identity"] = try Chatly.jsonObject(identity)
            }
        } else {
            _ = try await initSession(identity: identity)
        }
        return try await postData(path, body: retry, idempotencyKey: idempotencyKey, isRetry: true)
    }

    // MARK: - Persistence

    private func store(token: String) {
        guard !token.isEmpty, let cfg = config else { return }
        visitorToken = token
        storage.write(token, forKey: Chatly.tokenKey(cfg.channelPublicId))
    }

    /// Drop only the session credential, keeping the remembered identity so a
    /// recovery can replay it. Cleared from storage, not just memory —
    /// otherwise the next launch repeats the failure.
    private func dropToken() {
        visitorToken = nil
        if let cfg = config {
            storage.delete(Chatly.tokenKey(cfg.channelPublicId))
        }
    }

    private func remember(identity: WidgetIdentity) {
        rememberedIdentity = identity
        guard let cfg = config, let encoded = try? JSONEncoder().encode(identity),
              let text = String(data: encoded, encoding: .utf8) else { return }
        storage.write(text, forKey: Chatly.identityKey(cfg.channelPublicId))
    }

    private static func tokenKey(_ publicId: String) -> String { "\(publicId):visitorToken" }
    private static func identityKey(_ publicId: String) -> String { "\(publicId):identity" }

    private static func decodeIdentity(_ text: String?) -> WidgetIdentity? {
        guard let text, let data = text.data(using: .utf8) else { return nil }
        // A corrupt entry is indistinguishable from no entry as far as the
        // caller is concerned: re-init anonymously rather than throwing.
        return try? JSONDecoder().decode(WidgetIdentity.self, from: data)
    }

    /// `Encodable` → the JSON object shape a request body needs.
    internal static func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
    }

    /// `Encodable` → an array of JSON objects, for `attachments`.
    internal static func jsonArray<T: Encodable>(_ values: [T]) throws -> [[String: Any]] {
        let data = try JSONEncoder().encode(values)
        return ((try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]) ?? []
    }

    /// Best-effort `Encodable` → `[String: Any]` for the legacy methods whose
    /// published return type is the raw JSON body.
    internal static func rawObject<T: Encodable>(_ value: T) -> [String: Any] {
        return (try? jsonObject(value)) ?? [:]
    }

    /// Does this 403 mean "your session token is no good", as opposed to any
    /// of the other things a widget call can be forbidden for (a disallowed
    /// origin, a missing identity hash)? Only the session codes are cured by
    /// fetching a new token; retrying the others would just fail again, more
    /// slowly. Matched by prefix so both `visitor_session_upgrade_required`
    /// and `visitor_session_invalid` recover — and so does a future third.
    internal static func isStaleSession(_ data: Data) -> Bool {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let code = obj["code"] as? String else { return false }
        return code.hasPrefix("visitor_session_")
    }
}

public enum ChatlyError: Error {
    case notConfigured
    case http(status: Int)
}
