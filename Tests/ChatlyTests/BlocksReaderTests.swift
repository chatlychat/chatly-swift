import XCTest

@testable import Chatly

/// ``MessageRow/blocks`` and the reader that validates it.
///
/// ## What was wrong
///
/// `MessageRow` had no `blocks` property and the field was absent from
/// `CodingKeys`, so the envelope was dropped at decode — while the doc comment
/// on `Kind.rich` said "Render `blocks` when it is present". `rich` is the
/// most common non-text kind on a visitor thread (every bot card is one), so
/// every card, product grid and fulfilment timeline arrived as bare `body`
/// text, on iOS, with no error anywhere.
///
/// ## Why these tests decode real JSON
///
/// `WireVocabularyTests` records the lesson: a test that asserts the SDK
/// agrees with its own types passes for years' worth of wrong values. So every
/// case here goes through `JSONDecoder` on a real `/v1/widget/messages/list`
/// message body, exactly as the transport hands it over, and asserts on what
/// the reader made of it.
///
/// ## What these tests do NOT cover
///
/// The UIKit assembly — `ChatlyBlocksView`, `ChatlyCardView`,
/// `ChatlyBlockViews` — is inside `#if canImport(UIKit)`, which is FALSE under
/// `swift build` on macOS. It is compile-checked on every run by
/// `IOSBuildTests`, and nothing more. That is why every string a block renders
/// lives in `ChatlyBlockText` (Foundation only, covered by `BlocksTextTests`)
/// rather than inside a view: the parts that can be WRONG are testable, and
/// the part that is untestable only puts them into labels.
final class BlocksReaderTests: XCTestCase {

    // MARK: Helpers

    /// A real message body with `blocks` set to `json`, through the real decoder.
    private func row(_ json: String) throws -> MessageRow {
        let body = """
        {
          "id": "0190a5d0-7c3a-7000-8000-000000000001",
          "authorType": "bot",
          "kind": "rich",
          "body": "Here are two options",
          "attachments": [],
          "createdAt": "2026-10-27T12:00:00.000Z",
          "blocks": \(json)
        }
        """
        return try JSONDecoder().decode(MessageRow.self, from: Data(body.utf8))
    }

    private func read(_ json: String) throws -> ChatlyBlocksEnvelope? {
        ChatlyBlocks.read(try row(json).blocks)
    }

    /// One block, wrapped in a valid envelope.
    private func block(_ json: String) throws -> ChatlyBlock? {
        try read("{ \"v\": 1, \"blocks\": [\(json)] }")?.blocks.first
    }

    private func card(_ json: String) throws -> ChatlyCard? {
        guard case .card(let card)? = try block(json) else { return nil }
        return card
    }

    // MARK: The field exists at all

    func testRichMessageCarriesItsBlocksThroughDecode() throws {
        let decoded = try row("{ \"v\": 1, \"blocks\": [{ \"type\": \"divider\" }] }")
        XCTAssertEqual(decoded.kind, .rich)
        XCTAssertNotNil(decoded.blocks, "the envelope must survive the message decode")
        XCTAssertEqual(ChatlyBlocks.read(decoded.blocks)?.blocks, [.divider(id: nil)])
    }

    func testMessageWithNoBlocksKeyDecodesWithNone() throws {
        let body = """
        {
          "id": "m-1", "authorType": "agent", "kind": "text", "body": "hi",
          "attachments": [], "createdAt": "2026-10-27T12:00:00.000Z"
        }
        """
        let decoded = try JSONDecoder().decode(MessageRow.self, from: Data(body.utf8))
        XCTAssertNil(decoded.blocks)
        XCTAssertNil(ChatlyBlocks.read(decoded.blocks))
    }

    func testMessageRowRoundTripsWithoutInventingABlocksKey() throws {
        let original = MessageRow(id: "m-1",
                                  authorType: .agent,
                                  kind: .text,
                                  body: "hi",
                                  createdAt: "2026-10-27T12:00:00.000Z")
        let data = try JSONEncoder().encode(original)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["blocks"], "an absent envelope must not encode as null")
        XCTAssertEqual(try JSONDecoder().decode(MessageRow.self, from: data), original)
    }

    // MARK: Never throw, never refuse the whole message

    /// The rule the whole contract rests on: an app older than the server must
    /// draw what it can and drop the rest, silently.
    func testUnknownBlockTypeIsDroppedAndTheRestRenders() throws {
        let envelope = try read("""
        { "v": 1, "blocks": [
          { "type": "hologram", "spin": true },
          { "type": "text", "markdown": "Still here" }
        ] }
        """)
        XCTAssertEqual(envelope?.blocks, [.text(markdown: "Still here", id: nil)])
    }

    func testAMessageOfNothingButUnknownBlocksKeepsItsBodyText() throws {
        let decoded = try row("{ \"v\": 1, \"blocks\": [{ \"type\": \"hologram\" }] }")
        XCTAssertNil(ChatlyBlocks.read(decoded.blocks), "nothing drawable is no envelope")
        XCTAssertEqual(decoded.body, "Here are two options", "the fallback text is untouched")
    }

    func testMalformedEnvelopesReadAsNothingRatherThanThrowing() throws {
        let refused = [
            "\"a string where an object belongs\"",
            "123",
            "null",
            "true",
            "[]",
            "[{ \"type\": \"divider\" }]",                      // bare array, no envelope
            "{ \"v\": 2, \"blocks\": [{ \"type\": \"divider\" }] }",
            "{ \"blocks\": [{ \"type\": \"divider\" }] }",       // no version
            "{ \"v\": 1 }",                                      // no blocks
            "{ \"v\": 1, \"blocks\": \"divider\" }",
            "{ \"v\": 1, \"blocks\": [] }",
            "{ \"v\": 1, \"blocks\": [null, 7, \"x\", [], { }] }",
            "{ \"v\": true, \"blocks\": [{ \"type\": \"divider\" }] }",
            "{ \"v\": 1, \"blocks\": [{ \"type\": \"card\" }] }", // a card with no title
            "{ \"v\": 1, \"blocks\": [{ \"markdown\": \"no type\" }] }",
        ]
        for json in refused {
            XCTAssertNil(try read(json), "should read as nothing: \(json)")
        }
    }

    func testAnUnreadableBlockDoesNotTakeItsNeighboursWithIt() throws {
        let envelope = try read("""
        { "v": 1, "blocks": [
          { "type": "card" },
          { "type": "text", "markdown": "one" },
          { "type": "quick_replies", "options": [] },
          { "type": "text", "markdown": "two" }
        ] }
        """)
        XCTAssertEqual(envelope?.blocks,
                       [.text(markdown: "one", id: nil), .text(markdown: "two", id: nil)])
    }

    // MARK: The media guard

    func testOnlyHttpsImagesAreAdmitted() {
        XCTAssertTrue(ChatlyBlocks.isSafeMediaSrc("https://cdn.example.com/a.png"))
        for refused in [
            "http://cdn.example.com/a.png",             // a downgrade a shopper cannot see
            "data:image/png;base64,iVBORw0KGgo=",
            "javascript:alert(1)",
            "file:///etc/passwd",                       // the device's own disk
            "//cdn.example.com/a.png",                  // no scheme
            "https://",                                 // no host
            " https://cdn.example.com/a.png",           // untrimmed
            "https://cdn.example.com/a.png\n",
            "https://cdn.example.com/\u{0007}a.png",     // control character
            "",
            String(repeating: "https://a.example.com/", count: 200),   // over 2000 chars
        ] {
            XCTAssertFalse(ChatlyBlocks.isSafeMediaSrc(refused), "should refuse: \(refused)")
        }
    }

    /// A media block IS its image: nothing is left to draw once the src goes.
    func testMediaBlockGoesWhenItsSourceIsRefused() throws {
        XCTAssertNil(try block("{ \"type\": \"media\", \"kind\": \"image\", \"url\": \"http://x.example.com/a.png\", \"alt\": \"A\" }"))
        XCTAssertNil(try block("{ \"type\": \"media\", \"kind\": \"image\", \"url\": \"https://x.example.com/a.png\" }"),
                     "no alt is an unlabelled image to a screen reader")
        XCTAssertNil(try block("{ \"type\": \"media\", \"kind\": \"audio\", \"url\": \"https://x.example.com/a.mp3\", \"alt\": \"A\" }"),
                     "only image and video")
        XCTAssertEqual(try block("{ \"type\": \"media\", \"kind\": \"video\", \"url\": \"https://x.example.com/a.mp4\", \"alt\": \"A clip\" }"),
                       .media(kind: .video, url: "https://x.example.com/a.mp4", alt: "A clip", id: nil))
    }

    /// A card's image is NOT the card: the image goes and the card stays.
    func testAnUnsafeCardImageDropsTheImageNotTheCard() throws {
        let card = try card("{ \"type\": \"card\", \"title\": \"Lamp\", \"image\": \"http://x.example.com/l.png\" }")
        XCTAssertEqual(card?.title, "Lamp")
        XCTAssertNil(card?.image)
    }

    // MARK: The action allow-list

    func testActionHrefsAreAnAllowListOfThree() {
        XCTAssertTrue(ChatlyBlocks.isSafeActionHref("https://shop.example.com/cart"))
        XCTAssertTrue(ChatlyBlocks.isSafeActionHref("mailto:help@example.com"))
        XCTAssertTrue(ChatlyBlocks.isSafeActionHref("tel:+15551234567"))
        for refused in [
            "javascript:alert(1)",
            "http://shop.example.com",
            "sms:+15551234567",
            "itms-apps://apps.apple.com/app/id1",
            "myapp://deeplink",
            "file:///etc/passwd",
            "mailto:",
            "tel:",
            " https://shop.example.com",
        ] {
            XCTAssertFalse(ChatlyBlocks.isSafeActionHref(refused), "should refuse: \(refused)")
        }
    }

    func testAnActionNeedsItsLabelAndItsOwnPayloadField() throws {
        XCTAssertNil(try block("{ \"type\": \"actions\", \"actions\": [{ \"kind\": \"postback\", \"value\": \"v\" }] }"),
                     "no label")
        XCTAssertNil(try block("{ \"type\": \"actions\", \"actions\": [{ \"kind\": \"postback\", \"label\": \"Go\" }] }"),
                     "no value")
        XCTAssertNil(try block("{ \"type\": \"actions\", \"actions\": [{ \"kind\": \"teleport\", \"label\": \"Go\", \"value\": \"v\" }] }"),
                     "an unknown kind is dropped, and an empty actions block goes with it")
        XCTAssertNil(try block("{ \"type\": \"actions\", \"actions\": [{ \"kind\": \"url\", \"label\": \"Go\", \"href\": \"javascript:alert(1)\" }] }"),
                     "a url action is only as good as its href")
        guard case .actions(let actions, _)? = try block("""
        { "type": "actions", "actions": [
          { "kind": "url", "label": "Track", "href": "https://x.example.com/t" },
          { "kind": "postback", "label": "Yes", "value": "yes", "silent": true, "payload": { "a": 1 } },
          { "kind": "host_event", "label": "Pay", "event": "checkout", "id": "e1" },
          { "kind": "step", "label": "Book", "canvasId": "c1" },
          { "kind": "copy", "label": "Copy code", "text": "SAVE10" },
          { "kind": "navigate", "label": "Orders", "path": "/orders" }
        ] }
        """) else { return XCTFail("expected an actions block") }
        XCTAssertEqual(actions.map(\.kind), [.url, .postback, .hostEvent, .step, .copy, .navigate])
        XCTAssertEqual(actions.map(\.value),
                       ["https://x.example.com/t", "yes", "checkout", "c1", "SAVE10", "/orders"])
        XCTAssertTrue(actions[1].silent)
        XCTAssertNotNil(actions[1].data, "a postback's payload is kept untouched")
        XCTAssertEqual(actions[2].id, "e1")
        XCTAssertFalse(actions[0].silent, "silent defaults to off")
    }

    // MARK: Cards

    func testCardCollapsesAllThreeBadgeSpellings() throws {
        XCTAssertEqual(try card("{ \"type\": \"card\", \"title\": \"T\", \"badge\": \"Sale\" }")?.badge,
                       [ChatlyCardBadge(text: "Sale", tone: .neutral)],
                       "a bare string is every row stored before tones existed")
        XCTAssertEqual(try card("{ \"type\": \"card\", \"title\": \"T\", \"badge\": { \"text\": \"Great price\", \"tone\": \"success\" } }")?.badge,
                       [ChatlyCardBadge(text: "Great price", tone: .success)])
        XCTAssertEqual(try card("""
        { "type": "card", "title": "T", "badge": [
          "Sale",
          { "text": "Above typical", "tone": "warning" },
          { "text": "Final sale", "tone": "chartreuse" },
          { "tone": "danger" },
          42
        ] }
        """)?.badge,
                       [ChatlyCardBadge(text: "Sale", tone: .neutral),
                        ChatlyCardBadge(text: "Above typical", tone: .warning),
                        ChatlyCardBadge(text: "Final sale", tone: .neutral),
                       ],
                       "an unknown tone is coerced, not dropped; a badge with no text is dropped")
        XCTAssertEqual(try card("{ \"type\": \"card\", \"title\": \"T\", \"badge\": [] }")?.badge, [])
    }

    func testCardPriceIsDroppedRatherThanDrawnWrong() throws {
        XCTAssertEqual(try card("{ \"type\": \"card\", \"title\": \"T\", \"price\": { \"amount\": 4820, \"currency\": \"USD\" } }")?.price,
                       ChatlyMoney(amount: 4820, currency: "USD"))
        XCTAssertEqual(try card("{ \"type\": \"card\", \"title\": \"T\", \"price\": { \"amount\": 4820, \"currency\": \"USD\", \"compareAt\": 6000 } }")?.price,
                       ChatlyMoney(amount: 4820, currency: "USD", compareAt: 6000))
        for refused in [
            "{ \"amount\": \"4820\", \"currency\": \"USD\" }",     // a string renders as nonsense
            "{ \"amount\": 48.20, \"currency\": \"USD\" }",        // minor units are integers
            "{ \"amount\": -1, \"currency\": \"USD\" }",
            "{ \"amount\": 4820, \"currency\": \"usd\" }",         // ISO 4217 is upper case
            "{ \"amount\": 4820, \"currency\": \"DOLLARS\" }",
            "{ \"amount\": 4820 }",
            "{ \"currency\": \"USD\" }",
            "\"4820 USD\"",
            "true",
        ] {
            XCTAssertNil(try card("{ \"type\": \"card\", \"title\": \"T\", \"price\": \(refused) }")?.price,
                         "should refuse: \(refused)")
        }
        XCTAssertNil(try card("{ \"type\": \"card\", \"title\": \"T\", \"price\": { \"amount\": 4820, \"currency\": \"USD\", \"compareAt\": \"lots\" } }")?.price?.compareAt,
                     "a bad was-price loses the was-price, not the price")
    }

    func testCardVariantsKeepTriStateStock() throws {
        let variants = try card("""
        { "type": "card", "title": "T", "variants": [
          { "label": "Small", "value": "s" },
          { "label": "Medium", "value": "m", "inStock": true },
          { "label": "Large", "value": "l", "inStock": false },
          { "label": "Huge", "value": "h", "inStock": "false" },
          { "label": "No value" },
          { "value": "no-label" }
        ] }
        """)?.variants
        XCTAssertEqual(variants, [
            ChatlyCardVariant(label: "Small", value: "s"),
            ChatlyCardVariant(label: "Medium", value: "m", inStock: true),
            ChatlyCardVariant(label: "Large", value: "l", inStock: false),
            ChatlyCardVariant(label: "Huge", value: "h"),
        ], "the string \"false\" is neither true nor false and must not reach a renderer")
    }

    func testCardStockIsDroppedWhenItIsNotOneOfTheThree() throws {
        XCTAssertEqual(try card("{ \"type\": \"card\", \"title\": \"T\", \"stock\": \"low\" }")?.stock, .low)
        XCTAssertEqual(try card("{ \"type\": \"card\", \"title\": \"T\", \"stock\": \"out_of_stock\" }")?.stock, .outOfStock)
        XCTAssertNil(try card("{ \"type\": \"card\", \"title\": \"T\", \"stock\": \"backordered\" }")?.stock)
        XCTAssertNil(try card("{ \"type\": \"card\", \"title\": \"T\", \"stock\": 3 }")?.stock)
    }

    func testCardReactionsAreNarrowedDedupedAndTheChosenOneChecked() throws {
        XCTAssertEqual(try card("{ \"type\": \"card\", \"title\": \"T\", \"reactions\": [\"like\", \"like\", \"dislike\", \"shrug\"] }")?.reactions,
                       [.like, .dislike],
                       "two identical thumbs is a duplicate control")
        let chosen = try card("{ \"type\": \"card\", \"title\": \"T\", \"reactions\": [\"like\"], \"reaction\": \"like\" }")
        XCTAssertEqual(chosen?.reaction, .like)
        XCTAssertNil(try card("{ \"type\": \"card\", \"title\": \"T\", \"reactions\": [\"like\"], \"reaction\": \"dislike\" }")?.reaction,
                     "a chosen thumb the card does not offer cannot be un-pressed")
        XCTAssertNil(try card("{ \"type\": \"card\", \"title\": \"T\", \"reaction\": \"like\" }")?.reaction)
    }

    func testCardTapTargetIsNarrowedToFourKinds() throws {
        XCTAssertEqual(try card("{ \"type\": \"card\", \"title\": \"T\", \"action\": { \"kind\": \"url\", \"label\": \"Open\", \"href\": \"https://x.example.com\" } }")?.action?.kind,
                       .url)
        XCTAssertEqual(try card("{ \"type\": \"card\", \"title\": \"T\", \"action\": { \"kind\": \"navigate\", \"label\": \"Open\", \"path\": \"/p/1\" } }")?.action?.kind,
                       .navigate)
        XCTAssertNil(try card("{ \"type\": \"card\", \"title\": \"T\", \"action\": { \"kind\": \"postback\", \"label\": \"Yes\", \"value\": \"y\" } }")?.action,
                     "a silent message sent by tapping a photo reads as a mis-tap")
        XCTAssertNil(try card("{ \"type\": \"card\", \"title\": \"T\", \"action\": { \"kind\": \"copy\", \"label\": \"Copy\", \"text\": \"x\" } }")?.action)
        XCTAssertNil(try card("{ \"type\": \"card\", \"title\": \"T\", \"action\": { \"kind\": \"url\", \"label\": \"Open\", \"href\": \"javascript:alert(1)\" } }")?.action,
                     "stricter than the RN reader here, on purpose: this wraps the whole title")
    }

    // MARK: Grids

    func testGridDropsItsTrailingTileRatherThanTheCards() throws {
        guard case .cardGrid(let cards, let carousel, let more, _)? = try block("""
        { "type": "card_grid", "layout": "carousel", "cards": [
          { "title": "One" }, { "title": "Two" }, { "notitle": true }
        ], "more": { "label": "Show all 60", "action": { "kind": "step", "label": "More", "canvasId": "c" } } }
        """) else { return XCTFail("expected a grid") }
        XCTAssertEqual(cards.map(\.title), ["One", "Two"])
        XCTAssertTrue(carousel)
        XCTAssertNil(more, "a step tile is a button that shows no more cards")
    }

    func testGridTileKeepsAPageableAction() throws {
        guard case .cardGrid(_, let carousel, let more, _)? = try block("""
        { "type": "card_grid", "layout": "grid", "cards": [{ "title": "One" }],
          "more": { "label": "Show all 60", "action": { "kind": "postback", "label": "More", "value": "page:2" } } }
        """) else { return XCTFail("expected a grid") }
        XCTAssertFalse(carousel)
        XCTAssertEqual(more?.label, "Show all 60")
        XCTAssertEqual(more?.action.value, "page:2")
    }

    func testGridWithNoReadableCardIsDropped() throws {
        XCTAssertNil(try block("{ \"type\": \"card_grid\", \"cards\": [{ \"no\": \"title\" }] }"))
        XCTAssertNil(try block("{ \"type\": \"card_grid\", \"cards\": \"two\" }"))
    }

    // MARK: Timelines

    func testTimelineCoercesAnUnknownStateInsteadOfLosingTheRow() throws {
        guard case .orderStatus(let steps, _)? = try block("""
        { "type": "order_status", "steps": [
          { "label": "Ordered", "state": "done", "at": "2026-10-20T10:00:00.000Z" },
          { "label": "Payment failed", "state": "exploded" },
          { "label": "Shipped", "state": "current", "at": "not a date" },
          { "state": "done" }
        ] }
        """) else { return XCTFail("expected a timeline") }
        XCTAssertEqual(steps.map(\.label), ["Ordered", "Payment failed", "Shipped"],
                       "a row with no label is unreadable; a row with an odd state is not")
        XCTAssertEqual(steps[1].state, .pending, "coerced — a missing row reads as a skipped stage")
        XCTAssertEqual(steps[0].at, "2026-10-20T10:00:00.000Z")
        XCTAssertNil(steps[2].at, "an unparseable date is worse than no date")
    }

    func testTimelineWithNoReadableStepIsDropped() throws {
        XCTAssertNil(try block("{ \"type\": \"order_status\", \"steps\": [{ \"state\": \"done\" }] }"))
        XCTAssertNil(try block("{ \"type\": \"order_status\", \"steps\": [] }"))
    }

    // MARK: Tables

    func testTableCoercesAColumnAndDropsARow() throws {
        guard case .table(let columns, let rows, let caption, _)? = try block("""
        { "type": "table", "caption": "Which to buy",
          "columns": [{ "label": "Pro" }, { "nolabel": true }, { "label": "Max", "image": "http://x.example.com/m.png" }],
          "rows": [
            { "label": "Price", "cells": ["$10", "$20", "$30", "$40"] },
            { "label": "Weight", "cells": ["1kg"] },
            { "cells": ["x"] },
            { "label": "Mixed", "cells": ["ok", 7, null] }
          ] }
        """) else { return XCTFail("expected a table") }
        XCTAssertEqual(columns.map(\.label), ["Pro", "", "Max"],
                       "a blank heading keeps its POSITION so cells stay under the right column")
        XCTAssertNil(columns[2].image, "an unsafe heading image drops the image, not the column")
        XCTAssertEqual(rows.map(\.label), ["Price", "Weight", "Mixed"])
        XCTAssertEqual(rows[0].cells, ["$10", "$20", "$30"], "a longer row is truncated")
        XCTAssertEqual(rows[1].cells, ["1kg"], "a short row is fine and renders blanks")
        XCTAssertEqual(rows[2].cells, ["ok", "", ""], "a non-string cell keeps its position")
        XCTAssertEqual(caption, "Which to buy")
    }

    func testTableIsDroppedWithNoHeadingOrNoRow() throws {
        XCTAssertNil(try block("{ \"type\": \"table\", \"columns\": [{ \"x\": 1 }], \"rows\": [{ \"label\": \"Price\", \"cells\": [\"$10\"] }] }"),
                     "the headings are what make it a comparison rather than a list")
        XCTAssertNil(try block("{ \"type\": \"table\", \"columns\": [{ \"label\": \"Pro\" }], \"rows\": [] }"),
                     "a heading row over a blank space")
    }

    // MARK: The remaining types

    func testTheSimpleBlocksReadAsThemselves() throws {
        XCTAssertEqual(try block("{ \"type\": \"text\", \"markdown\": \"**Hi**\", \"id\": \"b1\" }"),
                       .text(markdown: "**Hi**", id: "b1"))
        XCTAssertNil(try block("{ \"type\": \"text\", \"markdown\": \"\" }"), "an empty body is no block")
        XCTAssertEqual(try block("{ \"type\": \"fields\", \"items\": [{ \"label\": \"Order\", \"value\": \"#8841\" }, { \"label\": \"x\" }] }"),
                       .fields(items: [ChatlyBlockField(label: "Order", value: "#8841")], id: nil))
        XCTAssertNil(try block("{ \"type\": \"fields\", \"items\": [{ \"label\": \"x\" }] }"))
        XCTAssertEqual(try block("{ \"type\": \"quick_replies\", \"options\": [{ \"label\": \"Yes\", \"value\": \"y\" }] }"),
                       .quickReplies(options: [ChatlyBlockField(label: "Yes", value: "y")], id: nil))
        XCTAssertEqual(try block("{ \"type\": \"place\", \"label\": \"Desk 4\", \"detail\": \"Floor 2\", \"ref\": 7 }"),
                       .place(label: "Desk 4", detail: "Floor 2", ref: nil, id: nil),
                       "a non-string ref is dropped, the place stays")
        XCTAssertNil(try block("{ \"type\": \"place\", \"detail\": \"Floor 2\" }"))
        XCTAssertEqual(try block("{ \"type\": \"status\", \"id\": \"s1\", \"text\": \"Looking…\", \"state\": \"running\" }"),
                       .status(id: "s1", text: "Looking…", state: .running))
        XCTAssertNil(try block("{ \"type\": \"status\", \"text\": \"Looking…\" }"),
                     "a status block exists to be patched, so its id is required")
        XCTAssertEqual(try block("{ \"type\": \"status\", \"id\": \"s1\", \"text\": \"Done\", \"state\": \"finished\" }"),
                       .status(id: "s1", text: "Done", state: nil),
                       "an unknown state is dropped; the text is the content")
        XCTAssertEqual(try block("{ \"type\": \"divider\", \"id\": \"d1\" }"), .divider(id: "d1"))
    }

    /// The two spatial fields this port deliberately omits (see ``ChatlyBlock``).
    /// They must not break the card or the grid that carries them.
    func testSpatialFieldsAreIgnoredWithoutLosingTheBlock() throws {
        XCTAssertEqual(try card("{ \"type\": \"card\", \"title\": \"Lamp\", \"model\": { \"url\": \"https://x.example.com/l.gltf\" } }")?.title,
                       "Lamp")
        guard case .cardGrid(let cards, _, _, _)? = try block("{ \"type\": \"card_grid\", \"placement\": \"shelf\", \"cards\": [{ \"title\": \"One\" }] }") else {
            return XCTFail("expected a grid")
        }
        XCTAssertEqual(cards.count, 1)
    }

    /// A full envelope of everything, which is what a shopping bot sends.
    func testAWholeShoppingReplyReadsEndToEnd() throws {
        let envelope = try read("""
        { "v": 1, "blocks": [
          { "type": "text", "markdown": "Two options:" },
          { "type": "card_grid", "layout": "carousel", "cards": [
            { "id": "c1", "title": "Desk lamp", "subtitle": "Warm white",
              "image": "https://cdn.example.com/l.png",
              "badge": ["Sale", { "text": "Great price", "tone": "success" }],
              "price": { "amount": 4820, "currency": "USD", "compareAt": 6000 },
              "stock": "low",
              "fields": [{ "label": "Ships", "value": "Tomorrow" }],
              "variants": [{ "label": "Black", "value": "b", "inStock": false }],
              "reactions": ["like", "dislike"], "reaction": "like",
              "action": { "kind": "url", "label": "Details", "href": "https://shop.example.com/l" },
              "actions": [{ "kind": "host_event", "label": "Buy now", "event": "checkout" }] },
            { "title": "Floor lamp" }
          ] },
          { "type": "order_status", "steps": [{ "label": "Ordered", "state": "done" }] },
          { "type": "divider" },
          { "type": "quick_replies", "options": [{ "label": "Something else", "value": "other" }] }
        ] }
        """)
        XCTAssertEqual(envelope?.blocks.count, 5)
        guard case .cardGrid(let cards, _, _, _)? = envelope?.blocks[1] else {
            return XCTFail("expected the grid second")
        }
        let lamp = try XCTUnwrap(cards.first)
        XCTAssertEqual(lamp.badge.count, 2)
        XCTAssertEqual(lamp.price?.compareAt, 6000)
        XCTAssertEqual(lamp.stock, .low)
        XCTAssertEqual(lamp.reaction, .like)
        XCTAssertEqual(lamp.actions.first?.kind, .hostEvent)
        XCTAssertEqual(lamp.action?.kind, .url)
        XCTAssertEqual(lamp.variants.first?.inStock, false)
    }

    /// `JSONSerialization` boxes numbers as `NSNumber` where `AnyCodable`
    /// boxes them as `Int64`, and a reader that only understood one of the two
    /// would work through the transport and fail for a consumer handing it a
    /// parsed dictionary.
    func testReadsAPlainJSONSerializationDictionaryToo() throws {
        let raw = try JSONSerialization.jsonObject(with: Data("""
        { "v": 1, "blocks": [{ "type": "card", "title": "T", "price": { "amount": 4820, "currency": "USD" } }] }
        """.utf8))
        let envelope = try XCTUnwrap(ChatlyBlocks.read(json: raw))
        guard case .card(let card) = envelope.blocks[0] else { return XCTFail("expected a card") }
        XCTAssertEqual(card.price, ChatlyMoney(amount: 4820, currency: "USD"))
    }
}
