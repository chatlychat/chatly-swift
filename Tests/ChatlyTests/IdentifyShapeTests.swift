import XCTest

@testable import Chatly

/// `identify()` must send an email-only identity, which the server accepts.
///
/// ═══ WHY ══════════════════════════════════════════════════════════════════
///
/// `WidgetIdentity.externalId` was a non-optional `String`, so this type
/// could not express the call its own SDK advertises, and `identify` built
/// the identity only inside `if let externalId`. An app calling
/// `identify(externalId: user.id, email: user.email)` where `user.id` is a
/// nil optional sent NO `identity` key at all — email, name, `userHash` and
/// attributes discarded client-side, after a 200. The agent inbox showed an
/// unnamed stranger with no reply address, for ever: Swift implements neither
/// `/v1/widget/profile` nor `/v1/widget/context`, so there is no second path
/// to name the contact.
///
/// The server has accepted this deliberately. `widgetInitSchema`'s
/// `externalId` is `.optional()` and its `.refine` admits `email` alone, with
/// a docblock recording that the change was made *because* every SDK
/// advertises an email-only `identify({ email })`.
///
/// ═══ WHY THE SUITE MISSED IT ══════════════════════════════════════════════
///
/// `RequestShapeTests` asserts on what the SDK SENT rather than on a canned
/// response, which is the right pattern and is why Swift's field names are
/// clean. Its only `identify` call passes `externalId: "u-42"`, so the nil
/// branch was untested in both directions. A request-asserting test only
/// catches what someone thought to assert.
final class IdentifyShapeTests: XCTestCase {

    private let publicId = "pub_test"

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func makeClient() -> Chatly {
        let client = Chatly()
        client.storage = MemoryStorage()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        client.urlSession = URLSession(configuration: cfg)
        client.configure(.init(channelPublicId: publicId,
                               baseURL: URL(string: "https://api.test")!))
        return client
    }

    private let initBody = """
    {"session":{"token":"vt-1","contactId":null,"workspaceId":"w-1",
    "brandId":"b-1","channelId":"ch-1","identityVerified":false,
    "hasReplyAddress":false},
    "workspace":{"id":"w-1","name":"Acme"},"branding":{},
    "realtimeUrl":null}
    """

    /// `Call.body` is already the decoded JSON object — see `StubURLProtocol`.
    private func sentIdentity() -> [String: Any]? {
        guard let call = StubURLProtocol.calls.last(where: { $0.path == "/v1/widget/init" })
        else { return nil }
        return call.body["identity"] as? [String: Any]
    }

    func testEmailOnlyIdentifyReachesTheWire() async throws {
        StubURLProtocol.handler = { [self] _ in (200, initBody) }
        let client = makeClient()

        // The exact shape that sent nothing: a nil id beside a real email.
        try await client.identify(externalId: nil, email: "buyer@example.com", name: "Buyer")

        let identity = sentIdentity()
        XCTAssertNotNil(identity, "an email-only identify sent no identity block at all")
        XCTAssertEqual(identity?["email"] as? String, "buyer@example.com")
        XCTAssertEqual(identity?["name"] as? String, "Buyer")
        // Omitted rather than null: the server's `.refine` counts KEYS, and a
        // literal null externalId is not the same as an absent one.
        XCTAssertNil(identity?["externalId"] ?? nil,
                     "a nil externalId must be omitted, not encoded as null")
    }

    func testIdentifyWithAnExternalIdStillSendsIt() async throws {
        StubURLProtocol.handler = { [self] _ in (200, initBody) }
        let client = makeClient()

        try await client.identify(externalId: "u-42", email: "buyer@example.com")

        let identity = sentIdentity()
        XCTAssertEqual(identity?["externalId"] as? String, "u-42")
        XCTAssertEqual(identity?["email"] as? String, "buyer@example.com")
    }

    func testIdentifyWithNothingAtAllSendsNoIdentityBlock() async throws {
        StubURLProtocol.handler = { [self] _ in (200, initBody) }
        let client = makeClient()

        // A no-op identify should stay one rather than send an empty object
        // the server would have to interpret.
        try await client.identify(externalId: nil)

        XCTAssertNil(sentIdentity())
    }
}
