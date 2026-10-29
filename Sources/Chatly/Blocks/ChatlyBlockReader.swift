import Foundation

/// Read a stored block envelope, refusing what cannot be drawn.
///
/// Mirrors `packages/shared/src/widget-blocks/read-envelope.ts` and the
/// published React Native SDK's `src/blocks/read-envelope.ts`, which is the
/// reference implementation. Foundation only and deliberately outside
/// `#if canImport(UIKit)`: `canImport(UIKit)` is FALSE under `swift build` on
/// macOS, so anything behind it is invisible to `swift test` (see
/// `IOSBuildTests`). The reader, the money formatting and every piece of
/// per-block text therefore live here, where the suite can reach them, and
/// only the views are in `UI/`.
///
/// ── The contract, which is the same on every renderer ──────────────────
///
/// Never throw, never render a hole. A row written before a field was
/// validated — or by a future server this app does not know about — must
/// produce the most of the message that CAN be drawn, not an error and not a
/// blank space. So:
///
///   an unreadable BLOCK is dropped, the rest of the message renders;
///   an unsafe card image drops the IMAGE, not the card;
///   an unreadable price drops the PRICE, because a formatter handed a string
///     renders nonsense at a shopper;
///   an unknown `type` is EXPECTED rather than exceptional — an old app meets
///     a newer server — and is dropped silently.
///
/// ── The media guard ────────────────────────────────────────────────────
///
/// `https:` only, no control characters, no untrimmed string, length capped.
/// `UIImageView` fed a `URLSession` will happily fetch `http:` and `data:`,
/// and a card is authored by whoever holds an API key — so the same refusal
/// the web widget applies in a browser applies here. `http:` on a phone is a
/// downgrade a shopper cannot see and `file:` is the device's own disk.
///
/// ── One deliberate difference from the React Native reader ─────────────
///
/// `card.action` — the tap target on a card's image and title — goes through
/// the SAME href allow-list as every other `url` action here. The RN reader
/// checks only that `href` is a non-empty string in that one position. This
/// is the stricter of the two and the difference can only ever refuse a tap
/// target that would have opened a non-`https:` scheme.
public enum ChatlyBlocks {

    // MARK: Entry points

    /// Read ``MessageRow/blocks`` — the untyped value straight off the row.
    public static func read(_ raw: AnyCodable?) -> ChatlyBlocksEnvelope? {
        read(json: raw?.value)
    }

    /// Read an envelope out of a plain `JSONSerialization` value.
    public static func read(json raw: Any?) -> ChatlyBlocksEnvelope? {
        guard let envelope = bag(raw),
              int(envelope["v"]) == ChatlyBlocksEnvelope.protocolVersion,
              let list = array(envelope["blocks"]) else { return nil }
        let blocks = list.compactMap { readBlock(json: $0) }
        return blocks.isEmpty ? nil : ChatlyBlocksEnvelope(blocks: blocks)
    }

    /// Read ONE block, or `nil` when it cannot be drawn. Exposed for a
    /// consumer rendering the envelope itself.
    public static func readBlock(json raw: Any?) -> ChatlyBlock? {
        guard let b = bag(raw), let type = b["type"] as? String else { return nil }
        let id = str(b["id"])
        switch type {
        case "text":
            guard let markdown = str(b["markdown"]) else { return nil }
            return .text(markdown: markdown, id: id)
        case "media":
            // Unlike a card's image, a media block IS its image: nothing is
            // left to render once the src is refused, so the block goes.
            guard let url = str(b["url"]), isSafeMediaSrc(url),
                  let alt = str(b["alt"]),
                  let kind = (b["kind"] as? String).flatMap(ChatlyBlock.MediaKind.init) else { return nil }
            return .media(kind: kind, url: url, alt: alt, id: id)
        case "fields":
            let items = readPairs(b["items"])
            return items.isEmpty ? nil : .fields(items: items, id: id)
        case "card":
            return readCard(b).map { ChatlyBlock.card($0) }
        case "card_grid":
            let cards = (array(b["cards"]) ?? []).compactMap { readCard(bag($0)) }
            guard !cards.isEmpty else { return nil }
            return .cardGrid(cards: cards,
                             carousel: b["layout"] as? String == "carousel",
                             more: readGridMore(b["more"]),
                             id: id)
        case "actions":
            let actions = readActions(b["actions"])
            return actions.isEmpty ? nil : .actions(actions: actions, id: id)
        case "quick_replies":
            let options = readPairs(b["options"])
            return options.isEmpty ? nil : .quickReplies(options: options, id: id)
        case "order_status":
            // No readable step is no timeline: a bordered blank space where
            // the answer to "where is my order" belongs.
            let steps = readTimelineSteps(b["steps"])
            return steps.isEmpty ? nil : .orderStatus(steps: steps, id: id)
        case "table":
            return readTable(b, id: id)
        case "place":
            guard let label = str(b["label"]) else { return nil }
            return .place(label: label, detail: str(b["detail"]), ref: str(b["ref"]), id: id)
        case "status":
            // `id` is required: a status block exists to be patched.
            guard let statusId = id, let text = str(b["text"]) else { return nil }
            return .status(id: statusId,
                           text: text,
                           state: (b["state"] as? String).flatMap(ChatlyBlock.StatusState.init))
        case "divider":
            return .divider(id: id)
        default:
            return nil
        }
    }

    // MARK: Guards

    /// `https:` and nothing else. Mirrors `isSafeMediaSrc` in the shared guard.
    public static func isSafeMediaSrc(_ src: String) -> Bool {
        isCleanReference(src) && scheme(of: src) == "https"
    }

    /// A url action's href: `https:`, `mailto:` or `tel:` — exactly the shared
    /// schema's set, nothing wider.
    ///
    /// `UIApplication.open` launches any scheme the device has a handler for,
    /// so the rule is an ALLOW-LIST of three: `javascript:`, `file:`, `sms:`,
    /// `itms-apps:` and an app's own scheme are all refused. The three
    /// admitted open the browser, a draft e-mail and the dialer with the
    /// number filled in; none acts without the visitor confirming.
    public static func isSafeActionHref(_ href: String) -> Bool {
        guard isCleanReference(href), let scheme = scheme(of: href) else { return false }
        return scheme == "https" || scheme == "mailto" || scheme == "tel"
    }

    private static func isCleanReference(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf16.count <= 2000 else { return false }
        if value.unicodeScalars.contains(where: { $0.value <= 0x1F || $0.value == 0x7F }) {
            return false
        }
        return value == value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The lower-cased scheme, or `nil` when the string is not a usable
    /// reference. `https:` additionally needs a host — `URLComponents` accepts
    /// `https://` with none, where the browser URL parser this mirrors throws.
    private static func scheme(of value: String) -> String? {
        guard let parts = URLComponents(string: value),
              let scheme = parts.scheme?.lowercased() else { return nil }
        if scheme == "https" {
            guard let host = parts.host, !host.isEmpty else { return nil }
        } else if parts.path.isEmpty && (parts.host ?? "").isEmpty {
            // `mailto:` / `tel:` carry no host, so the part after the colon is
            // the whole payload and an empty one is not a destination.
            return nil
        }
        return scheme
    }

    // MARK: Leaves

    private static func readAction(_ raw: Any?) -> ChatlyBlockAction? {
        guard let b = bag(raw),
              let label = str(b["label"]),
              let kind = (b["kind"] as? String).flatMap(ChatlyBlockAction.Kind.init) else { return nil }
        let value: String?
        switch kind {
        case .url: value = str(b["href"]).flatMap { isSafeActionHref($0) ? $0 : nil }
        case .postback: value = str(b["value"])
        case .hostEvent: value = str(b["event"])
        case .step: value = str(b["canvasId"])
        case .copy: value = str(b["text"])
        case .navigate: value = str(b["path"])
        }
        guard let payloadField = value else { return nil }
        let data = bag(b["payload"]) ?? bag(b["data"]) ?? bag(b["params"])
        return ChatlyBlockAction(kind: kind,
                                 label: label,
                                 value: payloadField,
                                 id: str(b["id"]),
                                 silent: bool(b["silent"]) == true,
                                 data: data.map { AnyCodable($0) })
    }

    private static func readActions(_ raw: Any?) -> [ChatlyBlockAction] {
        (array(raw) ?? []).compactMap { readAction($0) }
    }

    private static func readPairs(_ raw: Any?) -> [ChatlyBlockField] {
        (array(raw) ?? []).compactMap { entry in
            guard let b = bag(entry), let label = str(b["label"]), let value = str(b["value"]) else {
                return nil
            }
            return ChatlyBlockField(label: label, value: value)
        }
    }

    private static func readMoney(_ raw: Any?) -> ChatlyMoney? {
        guard let b = bag(raw),
              let amount = minorUnits(b["amount"]),
              let currency = b["currency"] as? String,
              currency.count == 3,
              currency.allSatisfy({ $0.isUppercase && $0.isASCII }) else { return nil }
        return ChatlyMoney(amount: amount, currency: currency, compareAt: minorUnits(b["compareAt"]))
    }

    /// Badges, collapsed to ONE shape: always `{ text, tone }`.
    ///
    /// `card.badge` accepts three spellings — a bare string (every stored row
    /// today), an object with a `tone`, or an array of up to two of either.
    /// A renderer branching on all three would be three branches, two of
    /// which nobody exercises.
    ///
    /// `tone` is COERCED and never dropped: it reaches a style, and dropping
    /// the badge over an unknown tone would delete the words "Final sale" to
    /// protect the colour of a pill.
    private static func readCardBadges(_ raw: Any?) -> [ChatlyCardBadge] {
        let entries = array(raw) ?? [raw as Any]
        return entries.compactMap { entry in
            if let text = str(entry) {
                return ChatlyCardBadge(text: text, tone: .neutral)
            }
            guard let b = bag(entry), let text = str(b["text"]) else { return nil }
            let tone: ChatlyBadgeTone
            switch b["tone"] as? String {
            case "success": tone = .success
            case "warning": tone = .warning
            case "danger": tone = .danger
            default: tone = .neutral
            }
            return ChatlyCardBadge(text: text, tone: tone)
        }
    }

    /// Variants, keeping only an option with both halves.
    ///
    /// `label` is what the shopper reads and `value` is what gets sent; an
    /// option missing either is unreadable or unanswerable, and one bad option
    /// loses that option, not the card. `inStock` is forced to
    /// absent-or-boolean, because the string `"false"` passed through would be
    /// truthy to one renderer and `!= false` to another.
    private static func readVariants(_ raw: Any?) -> [ChatlyCardVariant] {
        (array(raw) ?? []).compactMap { entry in
            guard let b = bag(entry), let label = str(b["label"]), let value = str(b["value"]) else {
                return nil
            }
            return ChatlyCardVariant(label: label, value: value, inStock: bool(b["inStock"]))
        }
    }

    /// A grid's trailing tile, narrowed to the three action kinds that can page.
    ///
    /// A `copy`, `host_event` or `step` tile would render as a button that
    /// shows no more cards. Dropping the tile keeps the grid — the cards are
    /// the substance.
    private static func readGridMore(_ raw: Any?) -> ChatlyGridMore? {
        guard let b = bag(raw), let label = str(b["label"]), let action = readAction(b["action"]),
              action.kind == .postback || action.kind == .url || action.kind == .navigate else {
            return nil
        }
        return ChatlyGridMore(label: label, action: action)
    }

    /// Timeline steps, with the state COERCED rather than the step dropped.
    ///
    /// Dropping a step whose state a later release invented (`failed`, say)
    /// removes a ROW from a timeline, and a timeline missing a row reads as an
    /// order that skipped a stage: the words "Payment failed" vanish and the
    /// shopper is told nothing. Coercing to `pending` keeps the label and the
    /// timestamp, and costs only the shape of a dot.
    ///
    /// `at` is dropped unless it parses, because a formatter handed an
    /// unparseable string prints nothing useful beside a fulfilment milestone.
    private static func readTimelineSteps(_ raw: Any?) -> [ChatlyOrderStatusStep] {
        (array(raw) ?? []).compactMap { entry in
            guard let b = bag(entry), let label = str(b["label"]) else { return nil }
            let state = (b["state"] as? String).flatMap(ChatlyOrderStatusStep.State.init) ?? .pending
            let at = str(b["at"]).flatMap { ChatlyBlockText.parseTimestamp($0) == nil ? nil : $0 }
            return ChatlyOrderStatusStep(label: label, at: at, state: state)
        }
    }

    /// A comparison table: the things across, their attributes down.
    ///
    /// ── Why a bad COLUMN is coerced and a bad ROW is dropped ───────────
    ///
    /// Not the same mistake. A row is identified by its own label, so a row
    /// without one is a line of values nobody can interpret and it goes. A
    /// COLUMN is identified by its POSITION: drop column 1 and every row's
    /// cells shift left, so a price is drawn under the wrong product — a wrong
    /// answer rather than a missing one. So an unreadable heading is coerced
    /// to an empty one and keeps its place.
    ///
    /// A table with no readable heading at all is dropped: the headings are
    /// what make it a comparison rather than a list.
    private static func readTable(_ raw: [String: Any], id: String?) -> ChatlyBlock? {
        let columns = (array(raw["columns"]) ?? []).map { entry -> ChatlyTableColumn in
            let b = bag(entry) ?? [:]
            return ChatlyTableColumn(label: str(b["label"]) ?? "",
                                     image: str(b["image"]).flatMap { isSafeMediaSrc($0) ? $0 : nil })
        }
        guard columns.contains(where: { !$0.label.isEmpty }) else { return nil }
        let rows = (array(raw["rows"]) ?? []).compactMap { entry -> ChatlyTableRow? in
            guard let b = bag(entry), let label = str(b["label"]) else { return nil }
            let cells = (array(b["cells"]) ?? []).prefix(columns.count).map { $0 as? String ?? "" }
            return ChatlyTableRow(label: label, cells: Array(cells))
        }
        // No readable row is no comparison: a heading row over a blank space.
        return rows.isEmpty ? nil : .table(columns: columns,
                                           rows: rows,
                                           caption: str(raw["caption"]),
                                           id: id)
    }

    private static func readCard(_ raw: Any?) -> ChatlyCard? {
        guard let b = bag(raw), let title = str(b["title"]) else { return nil }
        /*
         * The reaction pair is filtered to the two members and DEDUPED, then
         * the author's chosen one is checked against WHAT SURVIVED — a chosen
         * value naming a member the filter just dropped goes with it, because
         * a chosen thumb with no control behind it is something the shopper
         * cannot un-press. `['like','like']` is accepted by the write schema
         * (an enum of two with `.max(2)` cannot say "distinct") and draws two
         * identical thumbs.
         */
        var reactions: [ChatlyCardReaction] = []
        for entry in array(b["reactions"]) ?? [] {
            guard let reaction = (entry as? String).flatMap(ChatlyCardReaction.init),
                  !reactions.contains(reaction) else { continue }
            reactions.append(reaction)
        }
        let chosen = (b["reaction"] as? String).flatMap(ChatlyCardReaction.init)
        // Narrowed to the four kinds the schema allows on a card's tap target.
        // `postback` is excluded on purpose: a silent message sent by tapping
        // a photo is indistinguishable from a mis-tap.
        let tap = readAction(b["action"]).flatMap { action -> ChatlyBlockAction? in
            switch action.kind {
            case .url, .hostEvent, .step, .navigate: return action
            case .postback, .copy: return nil
            }
        }
        return ChatlyCard(
            id: str(b["id"]),
            title: title,
            subtitle: str(b["subtitle"]),
            image: str(b["image"]).flatMap { isSafeMediaSrc($0) ? $0 : nil },
            badge: b["badge"].map { readCardBadges($0) } ?? [],
            price: readMoney(b["price"]),
            fields: readPairs(b["fields"]),
            variants: readVariants(b["variants"]),
            stock: (b["stock"] as? String).flatMap(ChatlyCardStock.init),
            actions: readActions(b["actions"]),
            reactions: reactions,
            reaction: chosen.flatMap { reactions.contains($0) ? $0 : nil },
            action: tap
        )
    }

    // MARK: Primitives

    private static func bag(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    private static func array(_ value: Any?) -> [Any]? {
        value as? [Any]
    }

    /// A non-empty string, or `nil`. Mirrors the reference reader's `str`,
    /// where an empty string is as absent as a missing key.
    private static func str(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    /// A real JSON boolean, and nothing that merely looks like one.
    ///
    /// `value is Bool` is NOT this test and the difference cost a bug here:
    /// `JSONSerialization` boxes every number as `NSNumber`, and an
    /// `NSNumber` holding 1 or 0 answers `is Bool` with TRUE. So a guard
    /// written that way rejects the integer `1` — which is every envelope's
    /// `v`. Only `CFBoolean` is a boolean, and that is what this asks.
    /// `AnyCodable` hands over a Swift `Bool`, which bridges to `CFBoolean`
    /// too, so one check covers both paths.
    private static func isBoolean(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    /// `true`/`false`, or `nil` for anything else — including the string
    /// `"false"` and the number `1`. `card.variants[].inStock` is tri-state,
    /// so "the author did not say" has to stay distinguishable from `false`.
    private static func bool(_ value: Any?) -> Bool? {
        guard isBoolean(value) else { return nil }
        return value as? Bool
    }

    /// An integer out of JSON, refusing a fractional one and a boolean.
    ///
    /// `AnyCodable` boxes JSON integers as `Int64`, which does NOT bridge to
    /// `Int`, and `JSONSerialization` boxes them as `NSNumber`, which does —
    /// hence both branches.
    private static func int(_ value: Any?) -> Int? {
        if isBoolean(value) { return nil }
        switch value {
        case let i as Int: return i
        case let i as Int64: return Int(exactly: i)
        case let d as Double: return d == d.rounded() ? Int(exactly: d.rounded()) : nil
        default: return nil
        }
    }

    /// Minor units: a safe non-negative integer, and nothing else.
    private static func minorUnits(_ value: Any?) -> Int? {
        guard let amount = int(value), amount >= 0 else { return nil }
        return amount
    }
}
