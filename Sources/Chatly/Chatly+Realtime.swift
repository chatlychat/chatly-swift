import Foundation

/// Live delivery for the visitor's open conversation.
///
/// ── The two credentials, and why only one works ────────────────────────────
///
/// There are two visitor tokens and they are not interchangeable:
///
/// - **`session.token`** from `POST /v1/widget/init`. Long-lived, identifies
///   the visitor, and is what every REST call carries in its body. **The
///   realtime gateway does not accept it.**
/// - **The realtime token** from `POST /v1/widget/realtime/token`. HS256,
///   scoped to ONE conversation, 1h TTL.
///
/// The old `SocketTransport` was initialised with `authToken:` and its Kotlin
/// sibling's comment said to pass "the auth/session token from
/// `/v1/widget/init`" — the wrong credential, and there was no mint call in
/// either package.
public extension Chatly {
    /// `POST /v1/widget/realtime/token` — a conversation-scoped socket
    /// credential.
    ///
    /// 404s (`NotFoundError('Conversation')`) when the conversation is not
    /// this visitor's own, because the mint checks
    /// `conv.contactId === session.contactId`. It also re-runs `enforceOrigin`,
    /// and a native app sends no `Origin`/`Referer` — so it passes only
    /// because the channel has no origin allow-list configured. A customer who
    /// restricts origins for their website breaks their own mobile app; that
    /// is existing server behaviour, and the 403 it produces is surfaced as a
    /// 403 rather than swallowed as a generic network error.
    func mintRealtimeToken(conversationId: String) async throws -> RealtimeToken {
        return try await postDecoding(
            "/v1/widget/realtime/token",
            body: ["conversationId": conversationId]
        )
    }

    /// Open the live connection for one conversation.
    ///
    /// Returns `false` — and does nothing — when there is no conversation to
    /// scope a token to. That is not a failure: the realtime token names a
    /// conversation, so a visitor who has not started one has nothing to
    /// subscribe to. Call it again once ``startConversation(body:attachments:preChat:)``
    /// or ``listConversations(limit:)`` has produced an id.
    ///
    /// Switching conversations mints a NEW token and reconnects, because a
    /// reused socket keeps delivering the old conversation's events.
    @discardableResult
    func connectRealtime(conversationId: String? = nil) -> Bool {
        guard let target = conversationId ?? currentConversationId else {
            return false
        }
        if realtimeConversationId == target, realtime != nil {
            return true
        }
        disconnectRealtime()

        guard let url = resolvedRealtimeURL() else {
            return false
        }
        let transport = SocketTransport(
            realtimeURL: url,
            /*
             * Re-minted on every connection ATTEMPT, not captured once.
             *
             * This closure is the Swift equivalent of the browser widget's
             * `auth` CALLBACK (`apps/widget/src/realtime-client.ts:83-91`): a
             * static credential is replayed verbatim on every reconnect, so a
             * visitor whose socket dropped after the token's 1h lifetime
             * reconnects with an expired one and is refused silently for the
             * rest of the session.
             */
            mintToken: { [weak self] in
                guard let self = self else { throw ChatlyError.notConfigured }
                return try await self.mintRealtimeToken(conversationId: target).token
            },
            factory: webSocketFactory,
            backoff: realtimeBackoff
        )
        transport.onEnvelope = { [weak self] envelope in
            self?.onRealtimeEvent?(envelope)
        }
        realtime = transport
        realtimeConversationId = target
        currentConversationId = target
        Task { await transport.connect() }
        return true
    }

    /// Close the live connection and stop reconnecting.
    func disconnectRealtime() {
        realtime?.disconnect()
        realtime = nil
        realtimeConversationId = nil
    }

    /// The transport's current state, or `.disconnected` when there is none.
    var realtimeState: SocketTransportState {
        return realtime?.state ?? .disconnected
    }

    /// Tell the agent dashboard the visitor has read up to here.
    ///
    /// The gateway refuses this unless `readerType == "contact"`, `readerId`
    /// equals the token's own contact and `conversationId` equals the token's
    /// own conversation — so all three come from what the server told us, not
    /// from the caller. A no-op before `init` has produced a contact id.
    func markRead(upToMessageId: String? = nil) {
        guard let conversationId = realtimeConversationId,
              let contactId = sessionContactId else { return }
        var payload: [String: Any] = [
            "conversationId": conversationId,
            "readAt": Chatly.isoNow(),
            "readerType": "contact",
            "readerId": contactId,
        ]
        if let upToMessageId { payload["upToMessageId"] = upToMessageId }
        realtime?.emit("message.read", payload: payload)
    }

    /// Visitor typing, for the agent's "customer is writing" chip.
    ///
    /// The gateway DISCARDS the payload and rebuilds it from the token's
    /// claims (see `visitorTypingPublisher`), so this sends the ids only so
    /// the frame is well-formed if that ever changes.
    func setTyping(_ typing: Bool) {
        guard let conversationId = realtimeConversationId else { return }
        realtime?.emit(
            typing ? "typing.start" : "typing.stop",
            payload: [
                "conversationId": conversationId,
                "actorType": "contact",
                "actorId": sessionContactId ?? "unknown",
                "kind": "typing",
            ]
        )
    }

    /// Where to open the socket.
    ///
    /// Same precedence as the browser widget's `resolveRealtimeUrl`: an
    /// explicit ``Config/realtimeURL`` wins, then what `init` reported, then
    /// the `api.` → `realtime.` host convention — which is a last resort kept
    /// only so an older server is no worse off, and which has produced a host
    /// that does not resolve before now.
    internal func resolvedRealtimeURL() -> URL? {
        if let override = config?.realtimeURL {
            return override
        }
        if let reported = sessionRealtimeURL, !reported.isEmpty, let url = URL(string: reported) {
            return url
        }
        guard let base = config?.baseURL,
              var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return nil
        }
        if let host = comps.host, host.hasPrefix("api.") {
            comps.host = "realtime." + host.dropFirst("api.".count)
        }
        comps.path = ""
        comps.query = nil
        return comps.url
    }

    internal static func isoNow() -> String {
        let formatter = ISO8601DateFormatter()
        // `.withFractionalSeconds` because the gateway parses this with zod's
        // `.datetime()`, which accepts both — but the dashboard sorts read
        // receipts by it and second-resolution ties are a visible wobble.
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}
