import Foundation
#if canImport(UIKit)
import UIKit

/// Rich blocks inside a chat bubble.
///
/// ── What this fixes ────────────────────────────────────────────────────
///
/// `MessageRow.Kind.rich` is the most common non-text kind on a visitor
/// thread — every bot card is one — and until 2026-10-27 this SDK had no
/// `blocks` property at all. The envelope was dropped at decode, so every
/// card, product grid and fulfilment timeline arrived as bare `body` text
/// with no error anywhere.
///
/// ── What a press does, and what it cannot do ───────────────────────────
///
/// EVERY pressed action is handed to ``onAction``, and the SDK itself does
/// only what it can do without a transport it does not have. This client has
/// no `postback`, no canvas-step request and no `reportAction` method — the
/// React Native SDK runs those through its REST layer, and inventing wire
/// calls here would be guessing at a contract. So:
///
///   - `host_event` reaches ``onAction``, which is the posture it was
///     designed for: a card saying "Pay $48.20" has to run a payment sheet
///     with the buyer's real session, and that is the integrator's code.
///   - `postback` and `step` reach ``onAction`` too, and nothing else. They
///     are deliberately NOT mapped onto `Chatly.send(_:)`: a postback is not
///     a visitor message, and a `silent` one mapped to a send would put words
///     in the visitor's mouth.
///   - `url` additionally opens with `UIApplication.open` when no host
///     claimed it, after the `https:`/`mailto:`/`tel:` allow-list in
///     ``ChatlyBlocks/isSafeActionHref(_:)``.
///   - `copy` reaches ``onAction``. The clipboard is one line of UIKit, and
///     a copy the visitor cannot see happen reads as a dead button, so the
///     host decides what feedback to show.
///   - a `quick_replies` press goes to ``onQuickReply``, because a quick
///     reply IS an ordinary visitor message — the React Native SDK sends it
///     with `rest.reply`, and ``ChatlyViewController`` wires it to the same
///     path the composer uses.
///
/// ── Layout rulings a later reader will want to "fix" ───────────────────
///
///  1. Buttons stack in a COLUMN, where the web panel and the React Native
///     renderer wrap them in a row. UIKit has no flex wrap: a row of five
///     buttons either squeezes every label to ellipsis or scrolls sideways,
///     and the real alternative is a collection view with a flow layout —
///     a whole second layout engine for buttons that fit vertically.
///  2. A `carousel` is honoured because it is horizontal rather than narrow:
///     each card gets a fixed 240pt and the row scrolls. A `grid` layout is
///     a vertical STACK and never two columns — two cards side by side on a
///     phone are narrower than the images they carry.
///  3. The blocks sit on their own ``ChatlyTheme/bg`` panel inside the
///     bubble. A visitor's own bubble is `primary`-coloured with white text,
///     and card text at `fg` on that background fails contrast; one panel
///     rule is cheaper and safer than threading an outbound flag through
///     every label in two files.
public final class ChatlyBlocksView: UIView {
    /// Every pressed action, including the ones this SDK cannot run itself.
    public var onAction: ((ChatlyBlockAction) -> Void)?
    /// A pressed quick reply's `value`, to be sent as a visitor message.
    public var onQuickReply: ((String) -> Void)?

    private let stack = UIStackView()
    /// The panel's own padding, zeroed when there is nothing to draw.
    ///
    /// `isHidden` on a plain `UIView` does not collapse it in Auto Layout, so
    /// a constant 8pt inset would put 16pt of empty panel inside EVERY plain
    /// text bubble. Zeroing the four constants collapses the view to nothing
    /// without a competing height constraint to conflict with.
    private var padding: [NSLayoutConstraint] = []

    public init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = 10
        layer.cornerCurve = .continuous
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 6
        stack.alignment = .fill
        addSubview(stack)
        padding = [
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ]
        NSLayoutConstraint.activate(padding)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    /// Render the envelope on a message row, and report whether anything was
    /// drawn. `false` means the row carried no readable blocks and the view
    /// hid itself — the caller can skip the spacing it would have needed.
    @discardableResult
    public func render(_ blocks: AnyCodable?, theme: ChatlyTheme) -> Bool {
        for view in stack.arrangedSubviews {
            view.removeFromSuperview()
        }
        guard let envelope = ChatlyBlocks.read(blocks) else {
            isHidden = true
            setPadding(0)
            return false
        }
        isHidden = false
        setPadding(8)
        backgroundColor = theme.bg
        for block in envelope.blocks {
            stack.addArrangedSubview(view(for: block, theme: theme))
        }
        return true
    }

    private func setPadding(_ inset: CGFloat) {
        for (index, constraint) in padding.enumerated() {
            // Trailing and bottom are pinned with a negative constant.
            constraint.constant = index < 2 ? inset : -inset
        }
    }

    private func view(for block: ChatlyBlock, theme: ChatlyTheme) -> UIView {
        let run: (ChatlyBlockAction) -> Void = { [weak self] in self?.run($0) }
        switch block {
        case .text(let markdown, _):
            /*
             * Rendered as PLAIN text, deliberately. A markdown renderer is a
             * dependency and this package has none; the characters a bot
             * actually emits (`**bold**`, a bullet, a link) read acceptably
             * raw, and a consumer who wants more renders the envelope itself
             * — which is what `ChatlyBlocks.read` is public for.
             */
            return ChatlyBlockViews.label(markdown, theme: theme)
        case .media(let kind, let url, let alt, _):
            guard let parsed = URL(string: url) else {
                return ChatlyBlockViews.label(alt, theme: theme)
            }
            // No video player without a dependency. The alt text plus a
            // tappable link is strictly better than a blank space.
            return kind == .image
                ? ChatlyBlockViews.image(url: parsed, alt: alt, theme: theme, height: 180)
                : ChatlyBlockViews.button(ChatlyBlockAction(kind: .url, label: alt, value: url),
                                          theme: theme,
                                          run: run)
        case .fields(let items, _):
            return ChatlyBlockViews.lines(items.map(ChatlyBlockText.fieldLine),
                                          theme: theme,
                                          muted: true)
        case .card(let card):
            return ChatlyCardView.make(card: card, theme: theme, width: nil, run: run)
        case .cardGrid(let cards, let carousel, let more, _):
            return grid(cards: cards, carousel: carousel, more: more, theme: theme, run: run)
        case .actions(let actions, _):
            return ChatlyBlockViews.column(actions.map {
                ChatlyBlockViews.button($0, theme: theme, run: run)
            })
        case .quickReplies(let options, _):
            let row = ChatlyBlockViews.column(options.map { option in
                ChatlyBlockViews.chip(option.label, theme: theme) { [weak self] in
                    self?.onQuickReply?(option.value)
                }
            })
            row.accessibilityLabel = "Quick replies"
            return row
        case .orderStatus(let steps, _):
            /*
             * "Where is my order", answered in the thread. Nothing in it is a
             * control, and that is the block's design rather than this
             * renderer's restraint: there is no action, no amount and no
             * payment reference, because a checkout block would put this
             * package in the payment path.
             */
            let view = ChatlyBlockViews.column(steps.map { step in
                ChatlyBlockViews.label(ChatlyBlockText.stepLine(step),
                                       theme: theme,
                                       muted: step.state == .pending)
            }, spacing: 2)
            view.accessibilityLabel = "Order status"
            return view
        case .table(let columns, let rows, let caption, _):
            return table(columns: columns, rows: rows, caption: caption, theme: theme)
        case .place(let label, let detail, _, _):
            // No button: there is no world in a phone app, so the label IS
            // the block and a world host owns "take me there".
            let line = ChatlyBlockViews.label(ChatlyBlockText.placeLine(label: label, detail: detail),
                                              theme: theme)
            line.accessibilityLabel = "Place: \(line.text ?? label)"
            return line
        case .status(_, let text, let state):
            return ChatlyBlockViews.label(ChatlyBlockText.statusLine(text: text, state: state),
                                          theme: theme,
                                          muted: true)
        case .divider:
            let rule = UIView()
            rule.translatesAutoresizingMaskIntoConstraints = false
            rule.backgroundColor = theme.border
            rule.heightAnchor.constraint(equalToConstant: 1).isActive = true
            rule.accessibilityLabel = "divider"
            return rule
        }
    }

    private func grid(cards: [ChatlyCard],
                      carousel: Bool,
                      more: ChatlyGridMore?,
                      theme: ChatlyTheme,
                      run: @escaping (ChatlyBlockAction) -> Void) -> UIView {
        /*
         * The trailing tile's own LABEL is what renders, not the action's:
         * `more` carries both, and the tile is the thing the shopper reads.
         * Only the label is overridden, so the postback's value and the url's
         * href reach `run` exactly as authored.
         */
        var views = cards.map {
            ChatlyCardView.make(card: $0, theme: theme, width: carousel ? 240 : nil, run: run)
        }
        if let more = more {
            let action = ChatlyBlockAction(kind: more.action.kind,
                                           label: more.label,
                                           value: more.action.value,
                                           id: more.action.id,
                                           silent: more.action.silent,
                                           data: more.action.data)
            views.append(ChatlyBlockViews.button(action, theme: theme, run: run))
        }
        guard carousel else {
            return ChatlyBlockViews.column(views, spacing: 8)
        }
        let row = ChatlyBlockViews.column(views, spacing: 8)
        row.axis = .horizontal
        row.alignment = .top
        let scroller = UIScrollView()
        scroller.translatesAutoresizingMaskIntoConstraints = false
        scroller.showsHorizontalScrollIndicator = false
        scroller.accessibilityLabel = "Scrollable options"
        scroller.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: scroller.topAnchor),
            row.leadingAnchor.constraint(equalTo: scroller.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: scroller.trailingAnchor),
            row.bottomAnchor.constraint(equalTo: scroller.bottomAnchor),
            row.heightAnchor.constraint(equalTo: scroller.heightAnchor),
        ])
        return scroller
    }

    /// A comparison table as text lines.
    ///
    /// Plain lines rather than a `UICollectionView` grid: the widest cell on a
    /// phone decides the column width, and a real grid inside a chat bubble
    /// either scrolls sideways or truncates every value. The reader has
    /// already padded short rows and kept blank headings in position, so a
    /// cell always sits under the heading it belongs to.
    private func table(columns: [ChatlyTableColumn],
                       rows: [ChatlyTableRow],
                       caption: String?,
                       theme: ChatlyTheme) -> UIView {
        var views: [UIView] = []
        if let caption = caption {
            views.append(ChatlyBlockViews.label(caption, theme: theme, muted: true))
        }
        let header = ChatlyBlockViews.label(ChatlyBlockText.tableHeaderLine(columns), theme: theme)
        header.font = .systemFont(ofSize: 13, weight: .semibold)
        views.append(header)
        for row in rows {
            views.append(ChatlyBlockViews.label(ChatlyBlockText.tableRowLine(row, columns: columns),
                                                theme: theme,
                                                muted: true))
        }
        let stack = ChatlyBlockViews.column(views, spacing: 2)
        stack.accessibilityLabel = caption ?? "Comparison"
        return stack
    }

    /// Run one action: hand it to the host, then do what the SDK can.
    private func run(_ action: ChatlyBlockAction) {
        onAction?(action)
        guard action.kind == .url, ChatlyBlocks.isSafeActionHref(action.value),
              let url = URL(string: action.value) else { return }
        /*
         * Opened whether or not a host is listening. `onAction` is a
         * notification rather than an interception — a `Bool` return would be
         * a second contract for the host to get wrong, and a url action that
         * does nothing when nobody set a closure is a dead button. A host
         * that wants to route its own links knows its own hrefs.
         */
        UIApplication.shared.open(url)
    }
}
#endif
