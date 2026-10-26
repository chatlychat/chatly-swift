import Foundation

/// The visitor's own conversations: starting one, replying to it, and reading
/// it back.
///
/// ── Why these are new ──────────────────────────────────────────────────────
///
/// The package shipped a complete UIKit chat view that called
/// `startConversation`, `replyTo`, `listConversations` and `listMessages` on
/// this client, and the client had none of them. That compiled on macOS —
/// where `#if canImport(UIKit)` is false and the whole view is compiled out —
/// so `swift build` and `swift test` were both green while a third of the
/// library had never been handed to a compiler.
///
/// Each one is here rather than removed because the server has the route, the
/// sibling SDKs (`sdk-react-native`, `sdk-js`) expose it, and a chat view that
/// cannot list messages is not a chat view.
///
/// Every body below is the shape the zod schema in
/// `apps/api/src/modules/widget/widget.schemas.ts` actually parses. zod
/// **strips** an unknown key rather than erroring, so a misnamed field is not
/// a failure — the server does something else, or nothing, and answers 200.
/// `publicId` and `visitorToken` are added by ``Chatly/postData`` for every
/// call, which is why no method below passes them.
public extension Chatly {
    /// `POST /v1/widget/conversations` — open a thread with a first message.
    ///
    /// Schema: `widgetStartSchema`. `body` may be empty only when
    /// `attachments` is not (`.refine` → "Send a message or an attachment").
    @discardableResult
    func startConversation(body: String,
                           attachments: [Attachment]? = nil,
                           preChat: [String: String]? = nil) async throws -> StartResponse {
        var payload: [String: Any] = ["body": body]
        if let attachments, !attachments.isEmpty {
            payload["attachments"] = try Chatly.jsonArray(attachments)
        }
        if let preChat, !preChat.isEmpty {
            payload["preChat"] = preChat
        }
        let started: StartResponse = try await postDecoding("/v1/widget/conversations", body: payload)
        currentConversationId = started.conversation.id
        return started
    }

    /// `POST /v1/widget/messages` — reply in an existing thread.
    ///
    /// Schema: `widgetReplySchema`, which requires `conversationId`. The
    /// client's older `send(_:)` omitted it and 400'd on every call.
    @discardableResult
    func replyTo(conversationId: String,
                 body: String,
                 attachments: [Attachment]? = nil) async throws -> MessageRow {
        var payload: [String: Any] = ["conversationId": conversationId, "body": body]
        if let attachments, !attachments.isEmpty {
            payload["attachments"] = try Chatly.jsonArray(attachments)
        }
        currentConversationId = conversationId
        return try await postDecoding("/v1/widget/messages", body: payload)
    }

    /// `POST /v1/widget/conversations/list` — this visitor's own threads,
    /// newest activity first. Answers `{ conversations: [...] }`.
    ///
    /// A visitor who has never started one gets `[]`, not an error.
    func listConversations(limit: Int? = nil) async throws -> [ConversationSummary] {
        var payload: [String: Any] = [:]
        if let limit { payload["limit"] = limit }
        let page: ConversationListResponse = try await postDecoding(
            "/v1/widget/conversations/list", body: payload
        )
        if currentConversationId == nil {
            currentConversationId = page.conversations.first?.id
        }
        return page.conversations
    }

    /// `POST /v1/widget/conversations/{id}/read` — persist how far the
    /// visitor has read.
    ///
    /// The DURABLE half of a read receipt, and none of the four mobile SDKs
    /// had it: only the web widget ever called this route. All four render
    /// the unread badge from the server's own `unreadContactCount`, so
    /// without this the count could only go UP — it survived app restarts and
    /// the agent inbox never learned a native visitor had seen the thread.
    ///
    /// Distinct from `markRead(upToMessageId:)` in `Chatly+Realtime`, which
    /// emits the live "Read ✓" tick over the socket. That is advisory and
    /// goes with the connection; this is the row.
    ///
    /// `upToMessageId` is optional server-side — omitting it means "read as
    /// of now", which is what an app that does not track per-message
    /// visibility should send.
    @discardableResult
    func persistRead(conversationId: String? = nil,
                     upToMessageId: String? = nil) async throws -> Bool {
        guard let target = conversationId ?? currentConversationId else { return false }
        var payload: [String: Any] = [:]
        if let upToMessageId { payload["upToMessageId"] = upToMessageId }
        _ = try await post("/v1/widget/conversations/\(target)/read", body: payload)
        return true
    }

    /// `POST /v1/widget/messages/list` — one thread's messages, oldest first.
    /// Answers `{ messages: [...] }`. 404s on a conversation this visitor does
    /// not own.
    func listMessages(conversationId: String, limit: Int? = nil) async throws -> [MessageRow] {
        var payload: [String: Any] = ["conversationId": conversationId]
        if let limit { payload["limit"] = limit }
        let page: MessageListResponse = try await postDecoding(
            "/v1/widget/messages/list", body: payload
        )
        return page.messages
    }

    /// `POST /v1/widget/uploads/presign`, then the bytes, then the attachment.
    ///
    /// Three steps, and the middle one is **the raw bytes** — not multipart,
    /// not base64. `sdk-react-native` and `sdk-flutter` both post
    /// `{ filename, mimeType, data }` to the presign route, which accepts
    /// none of that shape and does not take bytes at all.
    ///
    /// The rename between step 1 and step 3 is real and deliberate: the
    /// presign request calls the media type `contentType`
    /// (`widgetPresignSchema`) and the attachment on a message calls it
    /// `mimeType` (`widgetAttachmentSchema`).
    ///
    /// The route refuses before presigning when attachments are off for the
    /// channel, when the type is outside `WIDGET_UPLOAD_MIME`, or when the
    /// file is over the channel's cap — each a `ValidationError` whose copy is
    /// written for the visitor to read.
    func uploadAttachment(_ data: Data,
                          filename: String,
                          mimeType: String) async throws -> Attachment {
        let presigned: PresignResponse = try await postDecoding(
            "/v1/widget/uploads/presign",
            body: [
                "filename": filename,
                "contentType": mimeType,
                "sizeBytes": data.count,
            ]
        )
        guard let target = URL(string: presigned.url) else {
            throw ChatlyError.http(status: -1)
        }
        var put = URLRequest(url: target)
        put.httpMethod = presigned.method
        // Every header the presign returned, or S3 rejects the signature.
        for (name, value) in presigned.headers {
            put.setValue(value, forHTTPHeaderField: name)
        }
        put.httpBody = data
        let (_, response) = try await urlSession.data(for: put)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw ChatlyError.http(status: status)
        }
        return Attachment(
            id: presigned.uploadId,
            url: presigned.publicUrl,
            filename: filename,
            mimeType: mimeType,
            sizeBytes: data.count
        )
    }

    /// `POST /v1/widget/kb/search` — the Help tab. Answers `{ results: [...] }`.
    func searchKb(query: String,
                  limit: Int? = nil,
                  locale: String? = nil,
                  profile: String? = nil) async throws -> [KbResult] {
        var payload: [String: Any] = ["query": query]
        if let limit { payload["limit"] = limit }
        if let locale { payload["locale"] = locale }
        if let profile { payload["profile"] = profile }
        let page: KbSearchResponse = try await postDecoding("/v1/widget/kb/search", body: payload)
        return page.results
    }

    /// `POST /v1/widget/kb/article` — one published article by slug. Answers
    /// `{ article: {...} }`, or 404 when the slug is outside this audience's
    /// help scope.
    func getKbArticle(slug: String, profile: String? = nil) async throws -> KbArticle {
        var payload: [String: Any] = ["slug": slug]
        if let profile { payload["profile"] = profile }
        let wrapper: KbArticleResponse = try await postDecoding(
            "/v1/widget/kb/article", body: payload
        )
        return wrapper.article
    }
}

// MARK: - Response envelopes

/// These exist because the widget routes answer with a NAMED key rather than a
/// bare array — `{ conversations: [] }`, `{ messages: [] }`, `{ results: [] }`,
/// `{ article: {} }`. A client that decoded the bare array would fail on every
/// successful response.
internal struct ConversationListResponse: Decodable {
    let conversations: [ConversationSummary]
}

internal struct MessageListResponse: Decodable {
    let messages: [MessageRow]
}

internal struct KbSearchResponse: Decodable {
    let results: [KbResult]
}

internal struct KbArticleResponse: Decodable {
    let article: KbArticle
}

internal extension Chatly {
    /// `postData` plus a decode, so each method above is its body and nothing
    /// else. Shares the one choke point, and therefore the idempotency key and
    /// the stale-session replay.
    func postDecoding<T: Decodable>(_ path: String, body: [String: Any]) async throws -> T {
        let data = try await postData(path, body: body)
        return try JSONDecoder().decode(T.self, from: data)
    }
}
