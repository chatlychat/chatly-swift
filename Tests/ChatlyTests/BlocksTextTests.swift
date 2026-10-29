import XCTest

@testable import Chatly

/// What a block RENDERS, as far as `swift test` can reach it.
///
/// `ChatlyBlocksView` and `ChatlyCardView` are inside `#if canImport(UIKit)`,
/// which is false under `swift build` on macOS — they are compile-checked by
/// `IOSBuildTests` and by nothing else. Every string they draw therefore lives
/// in `ChatlyBlockText`, so the parts of rendering that can be WRONG — the
/// money, the dates, the wording of a state — are covered here, and the views
/// only put them into labels.
final class BlocksTextTests: XCTestCase {

    /// A fixed locale, because the assertions are about the DIGITS, not about
    /// where the symbol goes. `formatAmount` defaults to the device's locale,
    /// which is the right default on a shopper's phone and the wrong one here.
    private let locale = Locale(identifier: "en_US")

    /// The bug a hand-rolled version ships with: `amount / 100` is perfect in
    /// USD, renders ¥4,820 as "¥48" and 4.820 KWD as "48.200 KWD" — wrong by
    /// two orders of magnitude in opposite directions.
    func testMoneyUsesEachCurrencysOwnMinorUnit() {
        XCTAssertEqual(ChatlyBlockText.formatAmount(4820, currency: "USD", locale: locale), "$48.20")
        XCTAssertEqual(ChatlyBlockText.formatAmount(4820, currency: "JPY", locale: locale), "¥4,820",
                       "three currencies have no minor unit at all")
        XCTAssertEqual(ChatlyBlockText.formatAmount(4820, currency: "KWD", locale: locale), "KWD\u{00A0}4.820",
                       "four have three digits")
        XCTAssertEqual(ChatlyBlockText.formatAmount(0, currency: "USD", locale: locale), "$0.00")
    }

    func testMoneyStillRendersForACurrencyTheFormatterDoesNotKnow() {
        // `NumberFormatter` prints an unrecognised code verbatim at two
        // digits rather than refusing, which is already the honest fallback.
        XCTAssertEqual(ChatlyBlockText.formatAmount(4820, currency: "ZZZ", locale: locale), "ZZZ\u{00A0}48.20")
        // A plain space here, where the line above has U+00A0: that one is
        // `NumberFormatter`'s own separator between a symbol-less currency
        // code and the amount, and this one is our fallback's `String(format:)`.
        XCTAssertEqual(ChatlyBlockText.plainAmount(4820, currency: "ZZZ"), "ZZZ 48.20")
    }

    func testWasPriceOnlyRendersWhenItIsAboveTheAskingPrice() {
        let discounted = ChatlyMoney(amount: 4820, currency: "USD", compareAt: 6000)
        XCTAssertEqual(ChatlyBlockText.formatPrice(discounted, locale: locale), "$48.20")
        XCTAssertEqual(ChatlyBlockText.comparePrice(discounted, locale: locale), "Was $60.00")
        XCTAssertNil(ChatlyBlockText.comparePrice(ChatlyMoney(amount: 4820, currency: "USD")))
        XCTAssertNil(ChatlyBlockText.comparePrice(ChatlyMoney(amount: 4820, currency: "USD", compareAt: 4820)),
                     "equal is not a discount")
        XCTAssertNil(ChatlyBlockText.comparePrice(ChatlyMoney(amount: 4820, currency: "USD", compareAt: 1000)),
                     "a was-price below the price is not a discount either")
    }

    func testTimestampsParseWithAndWithoutFractionalSeconds() {
        XCTAssertNotNil(ChatlyBlockText.parseTimestamp("2026-10-20T10:00:00.000Z"))
        XCTAssertNotNil(ChatlyBlockText.parseTimestamp("2026-10-20T10:00:00Z"))
        XCTAssertNil(ChatlyBlockText.parseTimestamp("tomorrow"))
        XCTAssertNil(ChatlyBlockText.parseTimestamp(""))
        XCTAssertEqual(ChatlyBlockText.formatTimestamp("tomorrow"), "",
                       "an unreadable date renders as nothing, never as a placeholder word")
    }

    /// The state is in WORDS beside the label: a coloured dot alone says
    /// nothing to a screen reader, and this surface has no dot.
    func testTimelineLinesNameTheirState() {
        XCTAssertEqual(ChatlyBlockText.stepLine(ChatlyOrderStatusStep(label: "Shipped", state: .current)),
                       "Shipped — In progress")
        XCTAssertEqual(ChatlyBlockText.stepLine(ChatlyOrderStatusStep(label: "Delivered", state: .pending)),
                       "Delivered — Pending")
        XCTAssertEqual(ChatlyBlockText.stepLine(ChatlyOrderStatusStep(label: "Bad date", at: "nope", state: .done)),
                       "Bad date — Done",
                       "no dangling separator when the time cannot be formatted")
        let dated = ChatlyBlockText.stepLine(
            ChatlyOrderStatusStep(label: "Ordered", at: "2026-10-20T10:00:00.000Z", state: .done))
        XCTAssertTrue(dated.hasPrefix("Ordered — Done · "), dated)
        XCTAssertFalse(dated.hasSuffix("· "), "a formatted time must actually be there")
    }

    func testStockAndStateWording() {
        XCTAssertEqual(ChatlyBlockText.stockLabel(.inStock), "In stock")
        XCTAssertEqual(ChatlyBlockText.stockLabel(.low), "Low stock")
        XCTAssertEqual(ChatlyBlockText.stockLabel(.outOfStock), "Out of stock",
                       "a surface rendering for a person writes its own label, not `out_of_stock`")
        XCTAssertEqual(ChatlyBlockText.stateLabel(.done), "Done")
    }

    /// Colour may never be the only carrier of meaning: "Great price" and
    /// "Above typical" are both badges and say opposite things.
    func testBadgesCarryTheirToneAsAGlyphAndAWord() {
        let success = ChatlyCardBadge(text: "Great price", tone: .success)
        XCTAssertEqual(ChatlyBlockText.badgeText(success), "\u{2713} Great price")
        XCTAssertEqual(ChatlyBlockText.badgeAccessibilityLabel(success), "Great price (positive)")
        let warning = ChatlyCardBadge(text: "Above typical", tone: .warning)
        XCTAssertEqual(ChatlyBlockText.badgeText(warning), "! Above typical")
        XCTAssertEqual(ChatlyBlockText.badgeAccessibilityLabel(warning), "Above typical (caution)")
        let danger = ChatlyCardBadge(text: "Final sale", tone: .danger)
        XCTAssertEqual(ChatlyBlockText.badgeText(danger), "\u{2715} Final sale")
        XCTAssertEqual(ChatlyBlockText.badgeAccessibilityLabel(danger), "Final sale (negative)")
        // `neutral` is the ABSENCE of a claim, so it gets neither — a plain
        // pill is the correct rendition of "Sale".
        let neutral = ChatlyCardBadge(text: "Sale", tone: .neutral)
        XCTAssertEqual(ChatlyBlockText.badgeText(neutral), "Sale")
        XCTAssertEqual(ChatlyBlockText.badgeAccessibilityLabel(neutral), "Sale")
    }

    func testReactionsAreWordsRatherThanThumbGlyphs() {
        XCTAssertEqual(ChatlyBlockText.reactionLabel(.like), "Helpful")
        XCTAssertEqual(ChatlyBlockText.reactionLabel(.dislike), "Not helpful")
    }

    func testFieldPlaceAndStatusLines() {
        XCTAssertEqual(ChatlyBlockText.fieldLine(ChatlyBlockField(label: "Order", value: "#8841")),
                       "Order: #8841")
        XCTAssertEqual(ChatlyBlockText.placeLine(label: "Desk 4", detail: "Floor 2"), "Desk 4 — Floor 2")
        XCTAssertEqual(ChatlyBlockText.placeLine(label: "Desk 4", detail: nil), "Desk 4")
        XCTAssertEqual(ChatlyBlockText.statusLine(text: "Looking…", state: .running), "Looking…")
        XCTAssertEqual(ChatlyBlockText.statusLine(text: "Found 6", state: nil), "Found 6")
        XCTAssertEqual(ChatlyBlockText.statusLine(text: "Search", state: .failed), "Search — failed",
                       "a failure is said, not coloured")
    }

    /// The positional rule the reader exists to protect, now at the other end:
    /// a short row pads out so every value stays under its own heading.
    func testTableLinesKeepCellsUnderTheirHeadings() {
        let columns = [ChatlyTableColumn(label: "Pro"),
                       ChatlyTableColumn(label: ""),
                       ChatlyTableColumn(label: "Max")]
        XCTAssertEqual(ChatlyBlockText.tableHeaderLine(columns), "Pro ·  · Max")
        XCTAssertEqual(
            ChatlyBlockText.tableRowLine(ChatlyTableRow(label: "Price", cells: ["$10", "$20", "$30"]),
                                         columns: columns),
            "Price: $10 · $20 · $30")
        XCTAssertEqual(
            ChatlyBlockText.tableRowLine(ChatlyTableRow(label: "Weight", cells: ["1kg"]),
                                         columns: columns),
            "Weight: 1kg ·  · ",
            "a short row renders blanks rather than shifting left")
    }
}
