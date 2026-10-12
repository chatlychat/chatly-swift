import XCTest
@testable import Chatly

/// Stale-session recovery for the iOS SDK.
///
/// When visitor tokens became signed envelopes, the server began refusing
/// pre-signature tokens with a 403 carrying `visitor_session_upgrade_required`
/// (or `visitor_session_invalid`). The browser widget recovers from that in
/// place; the mobile SDKs did not, so a mid-session visitor on an IDV-enabled
/// channel got one hard failure and then kept failing, because the dead token
/// stayed in the Keychain across launches.
///
/// These pin the recovery to the widget's exact semantics:
///   - only a 403, and only for `visitor_session_*` codes;
///   - exactly one retry;
///   - the replay re-inits with the REMEMBERED identity, so the contact — and
///     therefore the conversation history — comes back;
///   - the dead token is replaced in PERSISTENT storage, not just in memory;
///   - the `Idempotency-Key` is stable across the replay.
final class SessionRecoveryTests: XCTestCase {

    private let publicId = "pub_test"
    private var tokenKey: String { "\(publicId):visitorToken" }
    private var identityKey: String { "\(publicId):identity" }

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeClient(storage: MemoryStorage) -> Chatly {
        let client = Chatly()
        client.storage = storage
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        client.urlSession = URLSession(configuration: cfg)
        client.configure(.init(channelPublicId: publicId,
                               baseURL: URL(string: "https://api.test")!))
        return client
    }

    /// A store left behind by a previous app launch: a (now stale) token and
    /// the identity that launch successfully asserted.
    private func seededStorage() -> MemoryStorage {
        let storage = MemoryStorage()
        storage.write("stale-token", forKey: tokenKey)
        storage.write(#"{"externalId":"u-42","userHash":"deadbeef"}"#, forKey: identityKey)
        return storage
    }

    private func initPayload(token: String) -> String {
        """
        {"session":{"token":"\(token)","contactId":"c-1","workspaceId":"w-1",
        "brandId":"b-1","channelId":"ch-1"},
        "workspace":{"id":"w-1","name":"Acme"},"branding":{}}
        """
    }

    // MARK: - Tests

    func testReplaysOnceAfterReInitingWithTheRememberedIdentity() async throws {
        let storage = seededStorage()
        var sends = 0
        StubURLProtocol.handler = { [self] request in
            if request.path == "/v1/widget/init" {
                return (200, initPayload(token: "fresh-token"))
            }
            sends += 1
            return sends == 1
                ? (403, #"{"code":"visitor_session_upgrade_required"}"#)
                : (200, #"{"ok":true}"#)
        }

        let client = makeClient(storage: storage)
        _ = try await client.send("hello")

        // Exactly two calls to the original endpoint, one init wedged between.
        XCTAssertEqual(StubURLProtocol.calls.map(\.path),
                       ["/v1/widget/messages", "/v1/widget/init", "/v1/widget/messages"])

        // The re-init carried the remembered identity, so the replay lands on
        // the same contact and the visitor's history survives.
        let identity = StubURLProtocol.calls[1].body["identity"] as? [String: Any]
        XCTAssertEqual(identity?["externalId"] as? String, "u-42")
        XCTAssertEqual(identity?["userHash"] as? String, "deadbeef")
        // ...and did NOT re-send the token the server just refused.
        XCTAssertNil(StubURLProtocol.calls[1].body["visitorToken"])

        // The replay used the fresh token.
        XCTAssertEqual(StubURLProtocol.calls[0].body["visitorToken"] as? String, "stale-token")
        XCTAssertEqual(StubURLProtocol.calls[2].body["visitorToken"] as? String, "fresh-token")

        // A replayed write must coalesce server-side, not double-send.
        XCTAssertEqual(StubURLProtocol.calls[2].idempotencyKey,
                       StubURLProtocol.calls[0].idempotencyKey)
        XCTAssertNotEqual(StubURLProtocol.calls[2].idempotencyKey,
                          StubURLProtocol.calls[1].idempotencyKey)

        // Persisted, not just cached: the next launch must not repeat this.
        XCTAssertEqual(storage.read(tokenKey), "fresh-token")
    }

    func testRecoversVisitorSessionInvalidToo() async throws {
        let storage = seededStorage()
        var sends = 0
        StubURLProtocol.handler = { [self] request in
            if request.path == "/v1/widget/init" {
                return (200, initPayload(token: "fresh-token"))
            }
            sends += 1
            return sends == 1
                ? (403, #"{"code":"visitor_session_invalid"}"#)
                : (200, #"{"ok":true}"#)
        }

        let client = makeClient(storage: storage)
        _ = try await client.track("viewed_pricing")
        XCTAssertEqual(StubURLProtocol.calls.filter { $0.path == "/v1/widget/events" }.count, 2)
        XCTAssertEqual(storage.read(tokenKey), "fresh-token")
    }

    func testInitRebootsInPlaceWhenInitItselfIsRefused() async throws {
        let storage = seededStorage()
        var inits = 0
        StubURLProtocol.handler = { [self] _ in
            inits += 1
            return inits == 1
                ? (403, #"{"code":"visitor_session_invalid"}"#)
                : (200, initPayload(token: "fresh-token"))
        }

        let client = makeClient(storage: storage)
        _ = try await client.initSession()

        XCTAssertEqual(StubURLProtocol.calls.map(\.path), ["/v1/widget/init", "/v1/widget/init"])
        XCTAssertEqual(StubURLProtocol.calls[0].body["visitorToken"] as? String, "stale-token")
        XCTAssertNil(StubURLProtocol.calls[1].body["visitorToken"])
        let identity = StubURLProtocol.calls[1].body["identity"] as? [String: Any]
        XCTAssertEqual(identity?["externalId"] as? String, "u-42")
        XCTAssertEqual(storage.read(tokenKey), "fresh-token")
    }

    func testDoesNotRetryA403WithAnUnrelatedCode() async {
        let storage = seededStorage()
        StubURLProtocol.handler = { _ in (403, #"{"code":"widget_origin_not_allowed"}"#) }

        let client = makeClient(storage: storage)
        await XCTAssertThrowsErrorAsync(try await client.send("hello")) { error in
            guard case ChatlyError.http(let status) = error else {
                return XCTFail("expected ChatlyError.http, got \(error)")
            }
            XCTAssertEqual(status, 403)
        }

        // One attempt, no init: retrying an origin refusal just fails again.
        XCTAssertEqual(StubURLProtocol.calls.map(\.path), ["/v1/widget/messages"])
        // The token was NOT thrown away — it was never the problem.
        XCTAssertEqual(storage.read(tokenKey), "stale-token")
    }

    func testGivesUpAfterExactlyOneRetry() async {
        let storage = seededStorage()
        StubURLProtocol.handler = { [self] request in
            request.path == "/v1/widget/init"
                ? (200, initPayload(token: "fresh-token"))
                : (403, #"{"code":"visitor_session_invalid"}"#)
        }

        let client = makeClient(storage: storage)
        await XCTAssertThrowsErrorAsync(try await client.send("hello"))
        XCTAssertEqual(StubURLProtocol.calls.filter { $0.path == "/v1/widget/messages" }.count, 2)
    }

    func testDoesNotRetryANon403Failure() async {
        let storage = seededStorage()
        StubURLProtocol.handler = { _ in (500, #"{"code":"visitor_session_invalid"}"#) }

        let client = makeClient(storage: storage)
        await XCTAssertThrowsErrorAsync(try await client.send("hello"))
        XCTAssertEqual(StubURLProtocol.calls.count, 1)
    }

    func testRemembersIdentityOnlyAfterTheServerAcceptsIt() async throws {
        let storage = MemoryStorage()
        StubURLProtocol.handler = { [self] _ in (200, initPayload(token: "fresh-token")) }

        let client = makeClient(storage: storage)
        XCTAssertNil(storage.read(identityKey))
        _ = try await client.identify(externalId: "u-42", userHash: "deadbeef")
        XCTAssertNotNil(storage.read(identityKey))
        XCTAssertTrue(storage.read(identityKey)?.contains("deadbeef") == true)
    }

    func testResetForgetsTokenAndIdentity() {
        let storage = seededStorage()
        let client = makeClient(storage: storage)
        client.reset()
        XCTAssertNil(storage.read(tokenKey))
        XCTAssertNil(storage.read(identityKey))
    }
}

// MARK: - Test doubles

/// In-memory ``ChatlySessionStorage``. The real one writes to the Keychain,
/// which is not reliably available to a `swift test` process.
final class MemoryStorage: ChatlySessionStorage {
    private var values: [String: String] = [:]
    func read(_ key: String) -> String? { values[key] }
    func write(_ value: String, forKey key: String) { values[key] = value }
    func delete(_ key: String) { values.removeValue(forKey: key) }
}

/// Records every outbound request and answers from ``handler``.
final class StubURLProtocol: URLProtocol {
    struct Call {
        let path: String
        let body: [String: Any]
        let idempotencyKey: String?
    }

    /// `(status, jsonBody)` for a given request.
    static var handler: ((Call) -> (Int, String))?
    static private(set) var calls: [Call] = []

    static func reset() {
        handler = nil
        calls = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // `URLProtocol` strips `httpBody` off the request it hands us, so the
        // body has to be read back out of the body stream.
        let raw = request.httpBody ?? request.httpBodyStream.map(StubURLProtocol.drain) ?? Data()
        let call = Call(
            path: request.url?.path ?? "",
            body: ((try? JSONSerialization.jsonObject(with: raw)) as? [String: Any]) ?? [:],
            idempotencyKey: request.value(forHTTPHeaderField: "Idempotency-Key")
        )
        StubURLProtocol.calls.append(call)

        let (status, json) = StubURLProtocol.handler?(call) ?? (500, "{}")
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func drain(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

/// `XCTAssertThrowsError` has no async overload before Swift 6 concurrency
/// niceties; this is the minimal stand-in.
func XCTAssertThrowsErrorAsync(
    _ expression: @autoclosure () async throws -> some Any,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ inspect: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("expected an error to be thrown", file: file, line: line)
    } catch {
        inspect(error)
    }
}
