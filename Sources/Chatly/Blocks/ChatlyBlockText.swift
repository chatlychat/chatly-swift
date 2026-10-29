import Foundation

/// Every string a block renders, away from the views that draw it.
///
/// ── Why this is not inside the UIKit file ──────────────────────────────
///
/// `canImport(UIKit)` is FALSE under `swift build` on macOS, so anything
/// behind it is excluded from `swift test` — the bug `IOSBuildTests` exists
/// for, which hid nine compile errors for the whole life of this package. The
/// money formatting, the timeline lines, the stock and badge wording and the
/// table lines are the parts of rendering that can actually be WRONG, so they
/// live here where the suite runs them, and `UI/ChatlyBlocksView.swift` only
/// puts them into labels.
///
/// English literals, because this package has no translation layer — the same
/// call the React Native SDK makes. A consumer who needs another language
/// renders the envelope themselves, which ``ChatlyBlocks/read(_:)`` is public
/// for.
public enum ChatlyBlockText {

    // MARK: Money

    /// One amount in the DEVICE's locale.
    ///
    /// ── The divisor is not 100 ─────────────────────────────────────────
    ///
    /// `amount` is an integer count of the currency's smallest unit. Three
    /// currencies have no minor unit (JPY, KRW, VND) and four have three
    /// digits (KWD, BHD, JOD, OMR), so `amount / 100` renders ¥4,820 as "¥48"
    /// and 4.820 KWD as "48.200 KWD" — wrong by two orders of magnitude in
    /// opposite directions, and perfect in USD, which is why it would ship.
    /// The digit count is read off `NumberFormatter` after the currency code
    /// is set, so a currency added to CLDR after this was written is right
    /// with no table here.
    public static func formatAmount(_ amount: Int,
                                    currency: String,
                                    locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = locale
        formatter.currencyCode = currency
        let divisor = pow(10.0, Double(formatter.maximumFractionDigits))
        guard let formatted = formatter.string(from: NSNumber(value: Double(amount) / divisor)) else {
            return plainAmount(amount, currency: currency)
        }
        return formatted
    }

    /// The locale-free rendition, used as the fallback.
    public static func plainAmount(_ amount: Int, currency: String) -> String {
        String(format: "%@ %.2f", currency, Double(amount) / 100.0)
    }

    /// The price line on a card.
    public static func formatPrice(_ money: ChatlyMoney, locale: Locale = .current) -> String {
        formatAmount(money.amount, currency: money.currency, locale: locale)
    }

    /// The was-price line, or `nil`.
    ///
    /// A separate LINE rather than a struck-through amount beside the price:
    /// `NSAttributedString` strikethrough is the obvious version and reads as
    /// nothing at all to a screen reader, which is the same call the React
    /// Native renderer makes. Rendered only when `compareAt` is above
    /// `amount` — a "was" price below the asking price is not a discount.
    public static func comparePrice(_ money: ChatlyMoney, locale: Locale = .current) -> String? {
        guard let compareAt = money.compareAt, compareAt > money.amount else { return nil }
        return "Was \(formatAmount(compareAt, currency: money.currency, locale: locale))"
    }

    // MARK: Time

    /// Parse a stored ISO 8601 timestamp, with or without fractional seconds.
    ///
    /// The reader uses this to decide whether `order_status[].at` is keepable:
    /// a string no formatter can read renders as nothing beside a fulfilment
    /// milestone, and `at` is optional precisely because a pending step has
    /// none.
    public static func parseTimestamp(_ iso: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: iso) { return date }
        return ISO8601DateFormatter().date(from: iso)
    }

    /// A milestone's timestamp in the device's locale, or `""` when unreadable.
    public static func formatTimestamp(_ iso: String) -> String {
        guard let date = parseTimestamp(iso) else { return "" }
        return timestampFormatter.string(from: date)
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    // MARK: Blocks

    /// One timeline row.
    ///
    /// The state is written out in WORDS beside the label. A coloured dot
    /// alone says nothing to a screen reader, and this surface has no dot.
    /// An absent or unformattable time leaves no dangling separator.
    public static func stepLine(_ step: ChatlyOrderStatusStep) -> String {
        let when = step.at.map(formatTimestamp) ?? ""
        return "\(step.label) — \(stateLabel(step.state))\(when.isEmpty ? "" : " · \(when)")"
    }

    /// A timeline state in this surface's own words.
    ///
    /// The stored plain-text projection keeps the author's enum member
    /// verbatim because it is generated on the server and read back by a
    /// model; a surface rendering for a person writes its own label.
    public static func stateLabel(_ state: ChatlyOrderStatusStep.State) -> String {
        switch state {
        case .done: return "Done"
        case .current: return "In progress"
        case .pending: return "Pending"
        }
    }

    /// Availability in this surface's own words.
    public static func stockLabel(_ stock: ChatlyCardStock) -> String {
        switch stock {
        case .inStock: return "In stock"
        case .low: return "Low stock"
        case .outOfStock: return "Out of stock"
        }
    }

    /// What each tone adds BESIDES a colour, and why it has to add something.
    ///
    /// The rule is not "pick a legible colour", it is that colour may never be
    /// the only carrier of meaning: "Great price" and "Above typical" are both
    /// badges and they say opposite things in one pill, which is the entire
    /// reason `tone` exists. So a reader with no colour vision gets the glyph
    /// and a screen reader gets the word. `neutral` is the ABSENCE of a claim
    /// and gets neither — a plain pill is the correct rendition of "Sale",
    /// which is what every badge stored before tones existed is.
    public static func badgeGlyph(_ tone: ChatlyBadgeTone) -> String {
        switch tone {
        case .success: return "\u{2713}"
        case .warning: return "!"
        case .danger: return "\u{2715}"
        case .neutral: return ""
        }
    }

    /// The tone in a word, for the accessible name.
    public static func badgeToneWord(_ tone: ChatlyBadgeTone) -> String {
        switch tone {
        case .success: return "positive"
        case .warning: return "caution"
        case .danger: return "negative"
        case .neutral: return ""
        }
    }

    /// The badge as drawn: glyph then text.
    public static func badgeText(_ badge: ChatlyCardBadge) -> String {
        let glyph = badgeGlyph(badge.tone)
        return glyph.isEmpty ? badge.text : "\(glyph) \(badge.text)"
    }

    /// The badge as a screen reader hears it.
    public static func badgeAccessibilityLabel(_ badge: ChatlyCardBadge) -> String {
        let word = badgeToneWord(badge.tone)
        return word.isEmpty ? badge.text : "\(badge.text) (\(word))"
    }

    /// The pair in words. A lone thumb glyph says nothing to a screen reader.
    public static func reactionLabel(_ reaction: ChatlyCardReaction) -> String {
        switch reaction {
        case .like: return "Helpful"
        case .dislike: return "Not helpful"
        }
    }

    /// A `fields` row, a `card.fields` row.
    public static func fieldLine(_ field: ChatlyBlockField) -> String {
        "\(field.label): \(field.value)"
    }

    /// A `place` block: the label IS the block on a phone, since there is no
    /// world here to travel to.
    public static func placeLine(label: String, detail: String?) -> String {
        guard let detail = detail else { return label }
        return "\(label) — \(detail)"
    }

    /// A `status` block, with its failure said rather than coloured.
    public static func statusLine(text: String, state: ChatlyBlock.StatusState?) -> String {
        state == .failed ? "\(text) — failed" : text
    }

    /// A table's heading line. Blank headings keep their place, so the columns
    /// a row's cells sit under stay aligned.
    public static func tableHeaderLine(_ columns: [ChatlyTableColumn]) -> String {
        columns.map(\.label).joined(separator: " · ")
    }

    /// One table row: its own label, then a cell per column. A SHORT row is
    /// deliberately fine and renders blanks.
    public static func tableRowLine(_ row: ChatlyTableRow, columns: [ChatlyTableColumn]) -> String {
        let cells = (0..<columns.count).map { index in
            index < row.cells.count ? row.cells[index] : ""
        }
        return "\(row.label): \(cells.joined(separator: " · "))"
    }
}
