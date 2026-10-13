import XCTest
@testable import Chatly

/// Every request body, checked against the zod schema that parses it in
/// `apps/api/src/modules/widget/widget.schemas.ts`.
///
/// ── Why these are assertions about the REQUEST ─────────────────────────────
///
/// zod **strips** an unknown key rather than erroring. A misnamed field is
/// therefore not a failure: the server does a different thing, or nothing, and
/// answers 200. A stubbed transport that echoes whatever the SDK asked for
/// cannot see any of it — it agrees with the bug. So every assertion below is
/// on `StubURLProtocol.calls`, which records what went out.
final class RequestShapeTests: XCTestCase {

    private let publicId = "pub_test"

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeClient(realtimeUrl: String? = nil) -> Chatly {
        let client = Chatly()
        client.storage = MemoryStorage()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        client.urlSession = URLSession(configuration: cfg)
        client.realtimeBackoff = { _ in 0 }
        client.configure(.init(channelPublicId: publicId,
                               baseURL: URL(string: "https://api.test")!))
        return client
    }

    /// What `POST /v1/widget/init` really answers — `contactId` is
    /// `resolvedContact?.id ?? null`, i.e. **null until the visitor has
    /// actually started a conversation**.
    private func initPayload(contactId: String?, realtimeUrl: String? = nil) -> String {
        let contact = contactId.map { "\"\($0)\"" } ?? "null"
        let realtime = realtimeUrl.map { "\"\($0)\"" } ?? "null"
        return """
        {"session":{"token":"vt-1","contactId":\(contact),"workspaceId":"w-1",
        "brandId":"b-1","channelId":"ch-1","identityVerified":false,
        "hasReplyAddress":false},
        "workspace":{"id":"w-1","name":"Acme"},"branding":{},
        "realtimeUrl":\(realtime)}
        """
    }

    private let messageRow = """
    {"id":"m-1","authorType":"contact","kind":"text","body":"hello",
    "attachments":[],"createdAt":"2026-05-28T12:00:00.000Z"}
    """

    private func call(_ path: String) -> StubURLProtocol.Call? {
        return StubURLProtocol.calls.last { $0.path == path }
    }

    // MARK: - init

    /// `initSession()` threw on the very first launch of every fresh install,
    /// because `InitResponse.Session.contactId` was a non-optional `String`
    /// and the server sends `null` for a visitor who has not spoken. The token
    /// is persisted AFTER the decode, so the throw also meant the session was
    /// never stored — the SDK could not get started at all.
    func testInitDecodesASessionWithNoContactYet() async throws {
        StubURLProtocol.handler = { [self] _ in (200, initPayload(contactId: nil)) }
        let client = makeClient()
        let response = try await client.initSession()
        XCTAssertNil(response.session.contactId)
        XCTAssertEqual(response.session.token, "vt-1")
    }

    func testInitCarriesTheChannelPublicId() async throws {
        StubURLProtocol.handler = { [self] _ in (200, initPayload(contactId: nil)) }
        let client = makeClient()
        _ = try await client.initSession()
        XCTAssertEqual(call("/v1/widget/init")?.body["publicId"] as? String, publicId)
    }

    // MARK: - Uploads (widgetPresignSchema)

    /// `contentType`, never `mimeType`. `sdk-react-native` and `sdk-flutter`
    /// both send `{ filename, mimeType, data }` here; zod drops `mimeType` and
    /// then 400s on the missing `contentType`, and the route does not take
    /// bytes at all.
    func testPresignBodyUsesContentTypeAndNotMimeType() async throws {
        StubURLProtocol.handler = { request in
            if request.path == "/v1/widget/uploads/presign" {
                return (200, """
                {"uploadId":"up-1","url":"https://s3.test/key?sig=1","method":"PUT",
                 "headers":{"content-type":"image/png","x-amz-acl":"private"},
                 "publicUrl":"https://cdn.test/key","expiresAt":"2026-05-28T12:05:00.000Z"}
                """)
            }
            return (200, "{}")
        }
        let client = makeClient()
        _ = try await client.uploadAttachment(Data([0x89, 0x50, 0x4E, 0x47]),
                                              filename: "shot.png",
                                              mimeType: "image/png")

        let presign = try XCTUnwrap(call("/v1/widget/uploads/presign"))
        XCTAssertEqual(presign.body["contentType"] as? String, "image/png")
        XCTAssertNil(presign.body["mimeType"], "zod drops this key and then 400s on contentType")
        XCTAssertEqual(presign.body["sizeBytes"] as? Int, 4)
        XCTAssertEqual(presign.body["filename"] as? String, "shot.png")
        XCTAssertNil(presign.body["data"], "the presign route never carries the bytes")
    }

    /// Step 2 is the raw bytes to the presigned URL with every header it
    /// returned — not multipart, not base64, and not to the API host.
    func testUploadPutsTheRawBytesWithEveryPresignedHeader() async throws {
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D])
        StubURLProtocol.handler = { request in
            if request.path == "/v1/widget/uploads/presign" {
                return (200, """
                {"uploadId":"up-1","url":"https://s3.test/key?sig=1","method":"PUT",
                 "headers":{"content-type":"image/png","x-amz-acl":"private"},
                 "publicUrl":"https://cdn.test/key","expiresAt":"2026-05-28T12:05:00.000Z"}
                """)
            }
            return (200, "{}")
        }
        let client = makeClient()
        let attachment = try await client.uploadAttachment(bytes,
                                                           filename: "shot.png",
                                                           mimeType: "image/png")

        let put = try XCTUnwrap(StubURLProtocol.calls.last)
        XCTAssertEqual(put.url?.absoluteString, "https://s3.test/key?sig=1")
        XCTAssertEqual(put.method, "PUT")
        XCTAssertEqual(put.rawBody, bytes)
        XCTAssertEqual(put.header("content-type"), "image/png")
        XCTAssertEqual(put.header("x-amz-acl"), "private",
                       "a dropped presigned header is a signature mismatch")

        // Step 3's rename: the attachment on a message calls the same string
        // `mimeType`, and its id is the presign's `uploadId`.
        XCTAssertEqual(attachment.id, "up-1")
        XCTAssertEqual(attachment.mimeType, "image/png")
        XCTAssertEqual(attachment.url, "https://cdn.test/key")
        XCTAssertEqual(attachment.sizeBytes, 5)
    }

    // MARK: - Messages (widgetReplySchema / widgetStartSchema)

    func testReplyCarriesTheConversationId() async throws {
        StubURLProtocol.handler = { [self] _ in (200, messageRow) }
        let client = makeClient()
        _ = try await client.replyTo(conversationId: "cv-9", body: "hi")

        let reply = try XCTUnwrap(call("/v1/widget/messages"))
        XCTAssertEqual(reply.body["conversationId"] as? String, "cv-9",
                       "widgetReplySchema requires it; without it every send 400s")
        XCTAssertEqual(reply.body["body"] as? String, "hi")
        XCTAssertEqual(reply.body["visitorToken"] as? String, nil,
                       "no session yet, so nothing to send — but publicId still travels")
        XCTAssertEqual(reply.body["publicId"] as? String, publicId)
    }

    func testStartOmitsAnEmptyAttachmentsArray() async throws {
        StubURLProtocol.handler = { _ in
            (200, #"{"conversation":{"id":"cv-1"},"message":{"id":"m-1","body":"hi","createdAt":"2026-05-28T12:00:00.000Z"}}"#)
        }
        let client = makeClient()
        _ = try await client.startConversation(body: "hi")

        let start = try XCTUnwrap(call("/v1/widget/conversations"))
        XCTAssertEqual(start.body["body"] as? String, "hi")
        XCTAssertNil(start.body["attachments"], "the schema defaults it to []")
    }

    func testStartSendsAttachmentsInTheSchemasShape() async throws {
        StubURLProtocol.handler = { _ in
            (200, #"{"conversation":{"id":"cv-1"},"message":{"id":"m-1","body":"","createdAt":"2026-05-28T12:00:00.000Z"}}"#)
        }
        let client = makeClient()
        _ = try await client.startConversation(
            body: "",
            attachments: [Attachment(id: "up-1",
                                     url: "https://cdn.test/key",
                                     filename: "shot.png",
                                     mimeType: "image/png",
                                     sizeBytes: 5)]
        )
        let start = try XCTUnwrap(call("/v1/widget/conversations"))
        let attachments = try XCTUnwrap(start.body["attachments"] as? [[String: Any]])
        XCTAssertEqual(attachments.count, 1)
        // widgetAttachmentSchema: id, filename, mimeType, sizeBytes, url.
        XCTAssertEqual(Set(attachments[0].keys), ["id", "filename", "mimeType", "sizeBytes", "url"])
        XCTAssertEqual(attachments[0]["mimeType"] as? String, "image/png")
        XCTAssertNil(attachments[0]["contentType"], "`contentType` is the PRESIGN side's name")
    }

    /// `send(_:)` posted to `/v1/widget/messages` with no `conversationId`, so
    /// it could not succeed and no other method on the client would have given
    /// you an id to pass. It opens a thread now, and continues the one it
    /// opened.
    func testSendStartsAThreadAndThenContinuesIt() async throws {
        StubURLProtocol.handler = { [self] request in
            switch request.path {
            case "/v1/widget/conversations":
                return (200, #"{"conversation":{"id":"cv-1"},"message":{"id":"m-1","body":"first","createdAt":"2026-05-28T12:00:00.000Z"}}"#)
            default:
                return (200, messageRow)
            }
        }
        let client = makeClient()
        _ = try await client.send("first")
        _ = try await client.send("second")

        XCTAssertEqual(StubURLProtocol.calls.map(\.path),
                       ["/v1/widget/conversations", "/v1/widget/messages"])
        XCTAssertEqual(call("/v1/widget/messages")?.body["conversationId"] as? String, "cv-1")
    }

    /// The inline notification reply built its OWN request: no `publicId`, no
    /// `visitorToken`, and an `Authorization: Bearer` header the widget
    /// surface has never read. Three independent reasons for a 400, on the one
    /// call a visitor makes after the app has been backgrounded long enough
    /// for the token to need replacing.
    func testNotificationReplyGoesThroughTheWidgetSurface() async throws {
        StubURLProtocol.handler = { [self] _ in (200, messageRow) }
        let client = makeClient()
        client.storage.write("vt-stored", forKey: "\(publicId):visitorToken")
        client.configure(.init(channelPublicId: publicId,
                               baseURL: URL(string: "https://api.test")!))
        _ = try await client.handleNotificationReply(conversationId: "cv-7", text: "sure")

        let reply = try XCTUnwrap(call("/v1/widget/messages"))
        XCTAssertEqual(reply.body["publicId"] as? String, publicId)
        XCTAssertEqual(reply.body["visitorToken"] as? String, "vt-stored")
        XCTAssertEqual(reply.body["conversationId"] as? String, "cv-7")
        XCTAssertNil(reply.header("authorization"),
                     "the widget surface authenticates from the body, never a header")
        XCTAssertNotNil(reply.idempotencyKey)
    }

    // MARK: - Lists (named keys, not bare arrays)

    func testListsDecodeTheServersNamedKeys() async throws {
        StubURLProtocol.handler = { request in
            switch request.path {
            case "/v1/widget/conversations/list":
                return (200, """
                {"conversations":[{"id":"cv-1","status":"open","subject":null,
                 "lastMessagePreview":"hi","lastMessageAt":"2026-05-28T12:00:00.000Z",
                 "unreadContactCount":0,"createdAt":"2026-05-28T11:00:00.000Z"}]}
                """)
            case "/v1/widget/messages/list":
                return (200, """
                {"messages":[{"id":"m-1","authorType":"agent","kind":"rich","body":"hi",
                 "createdAt":"2026-05-28T12:00:00.000Z"}]}
                """)
            default:
                return (200, "{}")
            }
        }
        let client = makeClient()
        let conversations = try await client.listConversations(limit: 5)
        let messages = try await client.listMessages(conversationId: "cv-1", limit: 20)

        XCTAssertEqual(conversations.map(\.id), ["cv-1"])
        XCTAssertEqual(messages.map(\.id), ["m-1"])
        // `rich` is the kind every bot card arrives as, and it was missing
        // from the enum — so it decoded as `.text` and a host app branching
        // on it could not tell a product grid from a sentence.
        XCTAssertEqual(messages[0].kind, .rich)

        XCTAssertEqual(call("/v1/widget/conversations/list")?.body["limit"] as? Int, 5)
        XCTAssertEqual(call("/v1/widget/messages/list")?.body["conversationId"] as? String, "cv-1")
    }

    func testKbRoutesUnwrapResultsAndArticle() async throws {
        StubURLProtocol.handler = { request in
            switch request.path {
            case "/v1/widget/kb/search":
                return (200, #"{"results":[{"id":"kb-1","slug":"a","title":"A","excerpt":"…"}]}"#)
            case "/v1/widget/kb/article":
                return (200, """
                {"article":{"id":"kb-1","slug":"a","title":"A","body":"# A",
                 "bodyHtml":null,"updatedAt":"2026-05-28T12:00:00.000Z"}}
                """)
            default:
                return (200, "{}")
            }
        }
        let client = makeClient()
        let results = try await client.searchKb(query: "refund")
        let article = try await client.getKbArticle(slug: "a")
        XCTAssertEqual(results.map(\.slug), ["a"])
        XCTAssertEqual(article.title, "A")
        // An empty query is the BROWSE list server-side, so it is a legitimate
        // thing to send rather than a call to skip.
        XCTAssertEqual(call("/v1/widget/kb/search")?.body["query"] as? String, "refund")
    }

    // MARK: - Realtime, end to end through the client

    /// The whole defect, from `configure` to the frame on the wire: the socket
    /// must carry a token minted at `POST /v1/widget/realtime/token`, and NOT
    /// `session.token` from `init`.
    func testConnectRealtimeMintsItsOwnTokenAndDeclaresTheVisitorKind() async throws {
        StubURLProtocol.handler = { [self] request in
            switch request.path {
            case "/v1/widget/init":
                return (200, initPayload(contactId: "c-1", realtimeUrl: "https://rt.test"))
            case "/v1/widget/conversations":
                return (200, #"{"conversation":{"id":"cv-1"},"message":{"id":"m-1","body":"hi","createdAt":"2026-05-28T12:00:00.000Z"}}"#)
            case "/v1/widget/realtime/token":
                return (200, #"{"token":"rt-minted","expiresAt":"2026-05-28T13:00:00.000Z"}"#)
            default:
                return (200, messageRow)
            }
        }
        let factory = FakeSocketFactory()
        let client = makeClient()
        client.webSocketFactory = factory

        _ = try await client.initSession()
        _ = try await client.startConversation(body: "hi")
        XCTAssertTrue(client.connectRealtime())

        await waitUntil("a socket to be opened") { factory.sockets.count == 1 }
        factory.sockets[0].deliver(FakeSocket.openFrame)
        await waitUntil("the CONNECT frame") { !factory.sockets[0].frames.isEmpty }

        let auth = try XCTUnwrap(handshakeAuth(factory.sockets[0].frames[0]))
        XCTAssertEqual(auth["kind"] as? String, "visitor")
        XCTAssertEqual(auth["token"] as? String, "rt-minted")
        XCTAssertNotEqual(auth["token"] as? String, "vt-1",
                          "the session token is not accepted by the gateway")

        // The mint is conversation-scoped and says so.
        let mint = try XCTUnwrap(call("/v1/widget/realtime/token"))
        XCTAssertEqual(mint.body["conversationId"] as? String, "cv-1")
        XCTAssertEqual(mint.body["publicId"] as? String, publicId)
        XCTAssertEqual(mint.body["visitorToken"] as? String, "vt-1")

        // And it opened the gateway's own path on the host `init` reported.
        XCTAssertEqual(factory.sockets[0].url.absoluteString,
                       "wss://rt.test/socket.io/?EIO=4&transport=websocket")
    }

    /// The realtime token names ONE conversation, so there is nothing to
    /// subscribe to before the visitor has started a thread. The bundled view
    /// controller used to call this in `viewDidAppear` and claim the no-op was
    /// about a missing contact id.
    func testConnectRealtimeIsANoOpWithNoConversation() async throws {
        StubURLProtocol.handler = { [self] _ in (200, initPayload(contactId: nil)) }
        let factory = FakeSocketFactory()
        let client = makeClient()
        client.webSocketFactory = factory
        _ = try await client.initSession()

        XCTAssertFalse(client.connectRealtime())
        XCTAssertEqual(factory.sockets.count, 0)
    }

    /// Switching conversations mints again and opens a new socket: reusing one
    /// keeps delivering the previous conversation's events.
    func testSwitchingConversationsReconnects() async throws {
        StubURLProtocol.handler = { [self] request in
            switch request.path {
            case "/v1/widget/init":
                return (200, initPayload(contactId: "c-1", realtimeUrl: "https://rt.test"))
            case "/v1/widget/realtime/token":
                let conversationId = request.body["conversationId"] as? String ?? "?"
                return (200, #"{"token":"rt-\#(conversationId)","expiresAt":"2026-05-28T13:00:00.000Z"}"#)
            default:
                return (200, messageRow)
            }
        }
        let factory = FakeSocketFactory()
        let client = makeClient()
        client.webSocketFactory = factory
        _ = try await client.initSession()

        XCTAssertTrue(client.connectRealtime(conversationId: "cv-1"))
        await waitUntil("the first socket") { factory.sockets.count == 1 }
        XCTAssertTrue(client.connectRealtime(conversationId: "cv-2"))
        await waitUntil("the second socket") { factory.sockets.count == 2 }
        XCTAssertTrue(factory.sockets[0].isClosed)

        factory.sockets[1].deliver(FakeSocket.openFrame)
        await waitUntil("the second CONNECT frame") { !factory.sockets[1].frames.isEmpty }
        XCTAssertEqual(handshakeAuth(factory.sockets[1].frames[0])?["token"] as? String, "rt-cv-2")
    }

    /// `message.read` is refused by the gateway unless `readerType` is
    /// `contact` and `readerId` is the token's own contact, so all three ids
    /// come from the server rather than the caller.
    func testMarkReadAssertsOnlyWhatTheServerToldUs() async throws {
        StubURLProtocol.handler = { [self] request in
            switch request.path {
            case "/v1/widget/init":
                return (200, initPayload(contactId: "c-1", realtimeUrl: "https://rt.test"))
            case "/v1/widget/realtime/token":
                return (200, #"{"token":"rt-1","expiresAt":"2026-05-28T13:00:00.000Z"}"#)
            default:
                return (200, messageRow)
            }
        }
        let factory = FakeSocketFactory()
        let client = makeClient()
        client.webSocketFactory = factory
        _ = try await client.initSession()
        XCTAssertTrue(client.connectRealtime(conversationId: "cv-1"))

        await waitUntil("the first socket") { factory.sockets.count == 1 }
        let socket = factory.sockets[0]
        socket.deliver(FakeSocket.openFrame)
        await waitUntil("the CONNECT frame") { socket.frames.count == 1 }
        socket.deliver(#"40{"sid":"s1"}"#)
        await waitUntil("the connected state") { client.realtimeState == .connected }

        client.markRead(upToMessageId: "m-1")
        await waitUntil("the read receipt") { socket.frames.count == 2 }
        let event = try XCTUnwrap(emittedEvent(socket.frames[1]))
        XCTAssertEqual(event.name, "message.read")
        XCTAssertEqual(event.payload["readerType"] as? String, "contact")
        XCTAssertEqual(event.payload["readerId"] as? String, "c-1")
        XCTAssertEqual(event.payload["conversationId"] as? String, "cv-1")
        XCTAssertEqual(event.payload["upToMessageId"] as? String, "m-1")
        XCTAssertNotNil(event.payload["readAt"] as? String)
    }
}
