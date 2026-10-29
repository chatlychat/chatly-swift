import Foundation

/// The rich-block vocabulary, restated for this package.
///
/// Mirrors `packages/shared/src/widget-blocks/schema.ts` (which is zod, and
/// zod is not reachable from Swift) and the published React Native SDK's
/// `src/blocks/types.ts`, which is the reference implementation for every
/// mobile port. The canonical definition is the schema; this is a hand-written
/// mirror and `BlocksReaderTests` pins the shapes it accepts and refuses.
///
/// ── The documented subset ──────────────────────────────────────────────
///
/// All twelve block types the React Native renderer draws are here. TWO
/// fields are deliberately absent: `card.model` (a 3D model) and
/// `card_grid.placement` (how a world arranges cards). Both are spatial hints
/// that only a world host reads, and a UIKit table view is not one — see
/// `packages/core` and ADR 0063. Nothing else is omitted; nothing is invented.
///
/// ── Why these are structs and not enums with associated bags ───────────
///
/// ``MessageRow`` is `Hashable`, so everything reachable from it must be. A
/// dictionary of `Any` is not, which is why an action's per-kind payload is
/// one `value` string plus an ``AnyCodable`` for the optional object — the
/// house type for untyped JSON in this package, already `Codable & Hashable`.

/// A price on a card. `amount` and `compareAt` are both MINOR units.
///
/// 4820 is $48.20, 4820 is also ¥4,820, and 4820 is 4.820 KWD — the divisor
/// is NOT 100. ``ChatlyBlockText/formatPrice(_:locale:)`` reads the digit
/// count off the platform formatter.
public struct ChatlyMoney: Hashable {
    /// Integer count of the currency's smallest unit.
    public let amount: Int
    /// ISO 4217, upper case.
    public let currency: String
    /// The was-price. Rendered only when above ``amount``.
    public let compareAt: Int?

    public init(amount: Int, currency: String, compareAt: Int? = nil) {
        self.amount = amount
        self.currency = currency
        self.compareAt = compareAt
    }
}

/// One pressable thing: a card button, an `actions` entry, a grid's trailing tile.
///
/// One struct rather than a six-case enum, because every consumer of it —
/// ``ChatlyBlocksView`` and the host's own `onBlockAction` — wants the kind
/// and the one string that goes with it. ``value`` IS that string, named per
/// kind by the server: `href`, `value`, `event`, `canvasId`, `text`, `path`.
public struct ChatlyBlockAction: Hashable {
    /// What a press means. The six kinds the write schema accepts.
    public enum Kind: String, Hashable {
        /// Open ``value`` — `https:`, `mailto:` or `tel:` only.
        case url
        /// Send ``value`` back to the owning bot.
        case postback
        /// The app's own code runs: a payment sheet, a native screen, a cart.
        case hostEvent = "host_event"
        /// Ask for a canvas step by id.
        case step
        /// Put ``value`` on the clipboard.
        case copy
        /// Go to a path on the integrator's own site.
        case navigate
    }

    public let kind: Kind
    /// What the visitor reads on the control.
    public let label: String
    /// The kind's own payload field. Never empty — the reader drops an action without it.
    public let value: String
    /// `host_event.id` or `navigate.id`, when the author set one.
    public let id: String?
    /// `postback.silent` — a press that writes no visitor message.
    public let silent: Bool
    /// `postback.payload`, `host_event.data` or `step.params`, untouched.
    public let data: AnyCodable?

    public init(kind: Kind,
                label: String,
                value: String,
                id: String? = nil,
                silent: Bool = false,
                data: AnyCodable? = nil) {
        self.kind = kind
        self.label = label
        self.value = value
        self.id = id
        self.silent = silent
        self.data = data
    }
}

/// What a badge MEANS, not what colour it is.
///
/// "Great price" and "Above typical" are both badges and they say opposite
/// things, which is the one case a single pill cannot express.
public enum ChatlyBadgeTone: String, Hashable {
    case success, warning, danger, neutral
}

/// A badge as the READER hands it over, which is not what the server accepts.
///
/// The write vocabulary takes three spellings — a bare string, an object with
/// a `tone`, or an array of up to two of either — and the reader collapses all
/// three to this, with a bare string becoming ``ChatlyBadgeTone/neutral``. A
/// renderer therefore cannot get one of three branches wrong.
public struct ChatlyCardBadge: Hashable {
    public let text: String
    /// Always present: an absent tone would leave each renderer picking a default.
    public let tone: ChatlyBadgeTone

    public init(text: String, tone: ChatlyBadgeTone) {
        self.text = text
        self.tone = tone
    }
}

/// A reaction a card offers. An enum because the value travels to a bot.
public enum ChatlyCardReaction: String, Hashable {
    case like, dislike
}

/// One purchasable option on a card — a size, a colour, a plan tier.
public struct ChatlyCardVariant: Hashable {
    /// What the shopper reads.
    public let label: String
    /// What a program receives.
    public let value: String
    /// Tri-state ON PURPOSE: absent means the author did not say, which is not
    /// `false`. A renderer dims a `false` and leaves an absent one alone.
    public let inStock: Bool?

    public init(label: String, value: String, inStock: Bool? = nil) {
        self.label = label
        self.value = value
        self.inStock = inStock
    }
}

/// Whether the thing on the card can be bought right now. Three states, no count.
public enum ChatlyCardStock: String, Hashable {
    case inStock = "in_stock"
    case low
    case outOfStock = "out_of_stock"
}

/// A label/value pair — a `fields` row, a `card.fields` row, a quick reply.
public struct ChatlyBlockField: Hashable {
    public let label: String
    public let value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

/// One milestone on an `order_status` timeline.
public struct ChatlyOrderStatusStep: Hashable {
    /// Three states. An unrecognised one is COERCED to ``pending``, never dropped.
    public enum State: String, Hashable {
        case done, current, pending
    }

    public let label: String
    /// ISO 8601, and only ever a string a date parser accepted.
    public let at: String?
    public let state: State

    public init(label: String, at: String? = nil, state: State) {
        self.label = label
        self.at = at
        self.state = state
    }
}

/// One thing being compared, across the top of a `table`.
///
/// ``label`` is coerced to the empty string rather than dropped when
/// unreadable: a column is identified by its POSITION, so dropping it draws
/// every row's cells under the wrong heading.
public struct ChatlyTableColumn: Hashable {
    public let label: String
    public let image: String?

    public init(label: String, image: String? = nil) {
        self.label = label
        self.image = image
    }
}

/// One attribute, down the side of a `table`.
///
/// ``cells`` may be SHORTER than the table's columns and the trailing ones
/// render blank. It is never longer: the reader truncates it.
public struct ChatlyTableRow: Hashable {
    public let label: String
    public let cells: [String]

    public init(label: String, cells: [String]) {
        self.label = label
        self.cells = cells
    }
}

/// The trailing "show me more" tile on a grid.
///
/// Narrowed to the three action kinds that can page — a `copy`, `host_event`
/// or `step` tile is a button that silently shows no more cards, so the reader
/// drops the tile and keeps the grid.
public struct ChatlyGridMore: Hashable {
    /// What the shopper reads. Overrides the action's own label.
    public let label: String
    public let action: ChatlyBlockAction

    public init(label: String, action: ChatlyBlockAction) {
        self.label = label
        self.action = action
    }
}

/// One card: a product, a plan, a search result.
public struct ChatlyCard: Hashable {
    public let id: String?
    public let title: String
    public let subtitle: String?
    /// `https:` only — an unsafe src drops the IMAGE, not the card.
    public let image: String?
    /// Collapsed from the write schema's three spellings.
    public let badge: [ChatlyCardBadge]
    public let price: ChatlyMoney?
    public let fields: [ChatlyBlockField]
    public let variants: [ChatlyCardVariant]
    public let stock: ChatlyCardStock?
    public let actions: [ChatlyBlockAction]
    /// A like/dislike pair, filtered to the two members and deduped.
    public let reactions: [ChatlyCardReaction]
    /// What the AUTHOR says is chosen. Dropped unless ``reactions`` offers it.
    public let reaction: ChatlyCardReaction?
    /// Fired by tapping the card's image or title. `postback` is excluded on
    /// purpose: a silent message sent by tapping a photo reads as a mis-tap.
    public let action: ChatlyBlockAction?

    public init(id: String? = nil,
                title: String,
                subtitle: String? = nil,
                image: String? = nil,
                badge: [ChatlyCardBadge] = [],
                price: ChatlyMoney? = nil,
                fields: [ChatlyBlockField] = [],
                variants: [ChatlyCardVariant] = [],
                stock: ChatlyCardStock? = nil,
                actions: [ChatlyBlockAction] = [],
                reactions: [ChatlyCardReaction] = [],
                reaction: ChatlyCardReaction? = nil,
                action: ChatlyBlockAction? = nil) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.image = image
        self.badge = badge
        self.price = price
        self.fields = fields
        self.variants = variants
        self.stock = stock
        self.actions = actions
        self.reactions = reactions
        self.reaction = reaction
        self.action = action
    }
}

/// One block in a `rich` message's envelope.
public enum ChatlyBlock: Hashable {
    /// Rendered as PLAIN text: a markdown parser would be a dependency, and
    /// the characters a bot emits read acceptably raw. Same call as the RN SDK.
    case text(markdown: String, id: String?)
    /// An image, or a video as a tappable line (no video player without a dependency).
    case media(kind: MediaKind, url: String, alt: String, id: String?)
    case fields(items: [ChatlyBlockField], id: String?)
    case card(ChatlyCard)
    case cardGrid(cards: [ChatlyCard], carousel: Bool, more: ChatlyGridMore?, id: String?)
    case actions(actions: [ChatlyBlockAction], id: String?)
    case quickReplies(options: [ChatlyBlockField], id: String?)
    /// A read-only fulfilment timeline. Nothing in it is a control.
    case orderStatus(steps: [ChatlyOrderStatusStep], id: String?)
    case table(columns: [ChatlyTableColumn], rows: [ChatlyTableRow], caption: String?, id: String?)
    /// A named destination in words. No button: a world host owns "take me there".
    case place(label: String, detail: String?, ref: String?, id: String?)
    case status(id: String, text: String, state: StatusState?)
    case divider(id: String?)

    /// What a `media` block carries.
    public enum MediaKind: String, Hashable {
        case image, video
    }

    /// A `status` block's progress. Absent is the common case.
    public enum StatusState: String, Hashable {
        case running, done, failed
    }

    /// The author's own id for this block, when there is one. Used as a list key.
    public var id: String? {
        switch self {
        case .text(_, let id), .media(_, _, _, let id), .fields(_, let id),
             .actions(_, let id), .quickReplies(_, let id), .orderStatus(_, let id),
             .table(_, _, _, let id), .place(_, _, _, let id), .divider(let id),
             .cardGrid(_, _, _, let id):
            return id
        case .card(let card):
            return card.id
        case .status(let id, _, _):
            return id
        }
    }
}

/// A read envelope: the protocol version and the blocks that survived it.
public struct ChatlyBlocksEnvelope: Hashable {
    /// Bumped only on a breaking change to the envelope itself.
    public static let protocolVersion = 1

    public let v: Int
    /// Never empty — the reader returns `nil` rather than an envelope of nothing.
    public let blocks: [ChatlyBlock]

    public init(v: Int = ChatlyBlocksEnvelope.protocolVersion, blocks: [ChatlyBlock]) {
        self.v = v
        self.blocks = blocks
    }
}
