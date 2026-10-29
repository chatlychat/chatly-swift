import Foundation
#if canImport(UIKit)
import UIKit

/// The small UIKit pieces every block is built from.
///
/// One copy of each so two buttons in one thread cannot end up with
/// different accessible names or different touch targets — the reason the
/// React Native SDK exports `ActionButton` from `BlockCard.tsx` rather than
/// letting three `case`s each make their own.
enum ChatlyBlockViews {

    /// A body or muted line. `numberOfLines = 0`: a card title and a markdown
    /// paragraph both wrap, and a truncated price is a wrong price.
    static func label(_ text: String, theme: ChatlyTheme, muted: Bool = false) -> UILabel {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.numberOfLines = 0
        label.text = text
        label.font = .systemFont(ofSize: muted ? 12 : 14)
        label.textColor = muted ? theme.mutedFg : theme.fg
        return label
    }

    /// Several lines in one column.
    static func lines(_ texts: [String], theme: ChatlyTheme, muted: Bool = false) -> UIStackView {
        column(texts.map { label($0, theme: theme, muted: muted) }, spacing: 2)
    }

    /// A vertical stack. Buttons and cards both use it — see ruling 1 in
    /// ``ChatlyBlocksView``'s header for why nothing here wraps in a row.
    static func column(_ views: [UIView], spacing: CGFloat = 6) -> UIStackView {
        let stack = UIStackView(arrangedSubviews: views)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = spacing
        stack.alignment = .fill
        return stack
    }

    /// One action button.
    ///
    /// 44pt tall because that is the minimum touch target, and the label
    /// wraps rather than truncating: "Track my order" ellipsised to "Track
    /// my…" is a control whose consequence the visitor cannot read.
    static func button(_ action: ChatlyBlockAction,
                       theme: ChatlyTheme,
                       run: @escaping (ChatlyBlockAction) -> Void) -> UIView {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle(action.label, for: .normal)
        button.setTitleColor(theme.primary, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
        button.titleLabel?.numberOfLines = 0
        button.titleLabel?.textAlignment = .center
        button.layer.borderWidth = 1
        button.layer.borderColor = theme.border.cgColor
        button.layer.cornerRadius = 8
        button.layer.cornerCurve = .continuous
        button.contentEdgeInsets = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        if action.kind == .url {
            button.accessibilityTraits.insert(.link)
        }
        button.addAction(UIAction { _ in run(action) }, for: .touchUpInside)
        return button
    }

    /// A quick-reply chip: the same control, pill-shaped.
    static func chip(_ title: String,
                     theme: ChatlyTheme,
                     onPress: @escaping () -> Void) -> UIView {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle(title, for: .normal)
        button.setTitleColor(theme.fg, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 14)
        button.titleLabel?.numberOfLines = 0
        button.layer.borderWidth = 1
        button.layer.borderColor = theme.border.cgColor
        button.layer.cornerRadius = 18
        button.layer.cornerCurve = .continuous
        button.contentEdgeInsets = UIEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.addAction(UIAction { _ in onPress() }, for: .touchUpInside)
        return button
    }

    /// A block or card image.
    ///
    /// The src has already been through ``ChatlyBlocks/isSafeMediaSrc(_:)``,
    /// so this is only ever an `https:` fetch. `accessibilityLabel` is the
    /// author's `alt` — a card image with no alt would be an unlabelled image
    /// to a screen reader, which is why the schema requires one on `media`.
    static func image(url: URL, alt: String, theme: ChatlyTheme, height: CGFloat) -> UIView {
        let view = UIImageView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.contentMode = .scaleAspectFill
        view.clipsToBounds = true
        view.layer.cornerRadius = 8
        view.layer.cornerCurve = .continuous
        view.backgroundColor = theme.border
        view.isAccessibilityElement = true
        view.accessibilityTraits.insert(.image)
        view.accessibilityLabel = alt
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        ChatlyImageLoader.load(url) { [weak view] image in
            view?.image = image
        }
        return view
    }
}

/// Fetch-and-cache for inline images.
///
/// Lifted out of ``ChatlyMessageCell``, which had this inline with its own
/// static `NSCache`, so an attachment thumbnail and a card image share one
/// cache instead of two. The staleness check stays at the call site: only the
/// cell reuses its views, and only the cell knows which load it is still
/// waiting for.
enum ChatlyImageLoader {
    private static let cache = NSCache<NSString, UIImage>()

    /// Calls back on the MAIN queue, and only on success — a failed fetch
    /// leaves whatever placeholder the caller set.
    static func load(_ url: URL, completion: @escaping (UIImage) -> Void) {
        let key = url.absoluteString as NSString
        if let cached = cache.object(forKey: key) {
            completion(cached)
            return
        }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data = data, let image = UIImage(data: data) else { return }
            cache.setObject(image, forKey: key)
            DispatchQueue.main.async { completion(image) }
        }.resume()
    }
}
#endif
