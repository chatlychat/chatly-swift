import Foundation
#if canImport(UIKit)
import UIKit

/// ONE card, and everything that hangs off it, on a UIKit screen.
///
/// Split from ``ChatlyBlocksView`` for the reason the React Native SDK split
/// `BlockCard.tsx` from `MessageBlocks.tsx`: a CARD and the parts only a card
/// has (its badges, its reaction pair, its price, its buttons) against the
/// BLOCK LIST and the action runner that drives it. The 650-line ceiling
/// (`scripts/check-file-size.mjs`) is the other half of the reason.
///
/// Every string it draws comes from ``ChatlyBlockText``, which is Foundation
/// only and therefore testable — `canImport(UIKit)` is false under
/// `swift build` on macOS, so nothing in this file is reached by `swift test`
/// beyond the iOS compile that `IOSBuildTests` forces.
enum ChatlyCardView {

    /// Build the card. `width` is set for a carousel, where each card gets a
    /// fixed width and the row scrolls; `nil` means fill the bubble.
    static func make(card: ChatlyCard,
                     theme: ChatlyTheme,
                     width: CGFloat?,
                     run: @escaping (ChatlyBlockAction) -> Void) -> UIView {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.layer.borderWidth = 1
        container.layer.borderColor = theme.border.cgColor
        container.layer.cornerRadius = 12
        container.layer.cornerCurve = .continuous
        container.clipsToBounds = true

        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 4
        stack.alignment = .fill
        container.addSubview(stack)

        if let image = card.image, let url = URL(string: image) {
            stack.addArrangedSubview(ChatlyBlockViews.image(url: url,
                                                            alt: card.title,
                                                            theme: theme,
                                                            height: 140))
        }
        if !card.badge.isEmpty {
            stack.addArrangedSubview(badges(card.badge, theme: theme))
        }
        stack.addArrangedSubview(title(card, theme: theme, run: run))
        if let subtitle = card.subtitle {
            stack.addArrangedSubview(ChatlyBlockViews.label(subtitle, theme: theme, muted: true))
        }
        if let price = card.price {
            let line = ChatlyBlockViews.label(ChatlyBlockText.formatPrice(price), theme: theme)
            line.font = .systemFont(ofSize: 15, weight: .semibold)
            stack.addArrangedSubview(line)
            if let was = ChatlyBlockText.comparePrice(price) {
                stack.addArrangedSubview(ChatlyBlockViews.label(was, theme: theme, muted: true))
            }
        }
        if let stock = card.stock {
            stack.addArrangedSubview(ChatlyBlockViews.label(ChatlyBlockText.stockLabel(stock),
                                                            theme: theme,
                                                            muted: true))
        }
        for field in card.fields {
            stack.addArrangedSubview(ChatlyBlockViews.label(ChatlyBlockText.fieldLine(field),
                                                            theme: theme,
                                                            muted: true))
        }
        for variant in card.variants {
            stack.addArrangedSubview(self.variant(variant, theme: theme))
        }
        if !card.reactions.isEmpty {
            stack.addArrangedSubview(reactions(card, theme: theme))
        }
        for action in card.actions {
            stack.addArrangedSubview(ChatlyBlockViews.button(action, theme: theme, run: run))
        }

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
        ])
        if let width = width {
            container.widthAnchor.constraint(equalToConstant: width).isActive = true
        }
        return container
    }

    /// The title, which is also the card's tap target when it has one.
    ///
    /// ONE difference from the React Native renderer, and it is deliberate:
    /// there, the image AND the title are one pressable. A `UIImageView` is
    /// not a control, so making it tappable means a `UITapGestureRecognizer`,
    /// which has no closure API — it needs a target object to own a selector,
    /// and that object has to be retained by something. The title carries the
    /// same action with the same accessible name, and a `UIButton` gets the
    /// button trait, the 44pt touch target and VoiceOver's "double tap to
    /// activate" for free.
    private static func title(_ card: ChatlyCard,
                              theme: ChatlyTheme,
                              run: @escaping (ChatlyBlockAction) -> Void) -> UIView {
        guard let action = card.action else {
            let label = ChatlyBlockViews.label(card.title, theme: theme)
            label.font = .systemFont(ofSize: 15, weight: .semibold)
            return label
        }
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle(card.title, for: .normal)
        button.setTitleColor(theme.fg, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        button.titleLabel?.numberOfLines = 0
        button.contentHorizontalAlignment = .leading
        button.accessibilityLabel = "\(card.title), \(action.label)"
        button.addAction(UIAction { _ in run(action) }, for: .touchUpInside)
        return button
    }

    /// The badges on a card, all of them.
    ///
    /// Both, never the first: the common pair is a fact and a verdict —
    /// "Sale" beside "Above typical" — and drawing one shows the shopper half
    /// of what the author wrote. A column rather than a wrapping row, for the
    /// reason ``ChatlyBlockViews`` gives about UIKit having no flex wrap.
    ///
    /// NO tone gets a colour, and that gap is worth naming. ``ChatlyTheme``
    /// is this package's public theme contract and it carries `primary`,
    /// `bg`, `fg`, `mutedFg` and `border` — no success, warning or danger
    /// token. Hard-coding a green and a red here would be this file deciding
    /// what a consumer's palette means, and adding three tokens to a
    /// published theme struct is that file's call rather than this one's. The
    /// glyph and the accessible word carry the meaning anyway, which is the
    /// rule that matters: colour may never be the ONLY carrier of it.
    private static func badges(_ badges: [ChatlyCardBadge], theme: ChatlyTheme) -> UIView {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 2
        stack.alignment = .leading
        for badge in badges {
            let pill = ChatlyBlockViews.label(ChatlyBlockText.badgeText(badge), theme: theme)
            pill.font = .systemFont(ofSize: 11, weight: .medium)
            pill.accessibilityLabel = ChatlyBlockText.badgeAccessibilityLabel(badge)
            stack.addArrangedSubview(pill)
        }
        return stack
    }

    /// One pickable option.
    ///
    /// Drawn, not pickable: picking one means sending the chosen `value`
    /// somewhere, and this SDK has no postback transport (see
    /// ``ChatlyBlocksView``). `inStock` is tri-state, so only an explicit
    /// `false` is dimmed — and the words go in the accessible name, because
    /// alpha is not information a screen reader can read.
    private static func variant(_ variant: ChatlyCardVariant, theme: ChatlyTheme) -> UILabel {
        let label = ChatlyBlockViews.label(variant.label, theme: theme, muted: true)
        if variant.inStock == false {
            label.alpha = 0.5
            label.accessibilityLabel = "\(variant.label) (out of stock)"
        }
        return label
    }

    /// The reaction pair: drawn, and NOT pressable.
    ///
    /// The one deliberately unfinished thing here, and the same state the
    /// React Native renderer shipped in before it had a transport. A press
    /// means a SILENT postback carrying `card.reaction` as its value, and
    /// there is no postback method on this client at all — so a pressable
    /// thumb would be a control that does nothing, which is worse than a
    /// label. ``ChatlyCard/reaction`` (the author's own verdict, which is what
    /// the bot is ranking on) is marked selected so reopening the app shows
    /// it rather than an un-pressed thumb.
    private static func reactions(_ card: ChatlyCard, theme: ChatlyTheme) -> UIView {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = 8
        stack.alignment = .center
        for reaction in card.reactions {
            let chosen = card.reaction == reaction
            let label = ChatlyBlockViews.label(ChatlyBlockText.reactionLabel(reaction),
                                               theme: theme,
                                               muted: !chosen)
            label.font = .systemFont(ofSize: 12, weight: chosen ? .semibold : .regular)
            if chosen {
                label.accessibilityTraits.insert(.selected)
            }
            stack.addArrangedSubview(label)
        }
        stack.addArrangedSubview(UIView())
        return stack
    }
}
#endif
