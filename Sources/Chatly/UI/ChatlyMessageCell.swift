import Foundation
#if canImport(UIKit)
import UIKit

/// Table-view cell rendering one chat bubble.
///
/// Lays out a left- or right-aligned rounded bubble with the body, author
/// label, attachment previews, and a short relative time stamp. Designed for
/// ``ChatlyMessagesView``.
public final class ChatlyMessageCell: UITableViewCell {
    /// Reuse identifier registered with the table view.
    public static let reuseIdentifier = "ChatlyMessageCell"

    private let bubble = UIView()
    private let bodyLabel = UILabel()
    private let attachmentsStack = UIStackView()
    /// The `rich` message's blocks — a card, a product grid, a fulfilment
    /// timeline. Collapses to nothing on a message that carries none.
    private let blocksView = ChatlyBlocksView()
    private var blocksTop: NSLayoutConstraint?
    private let metaLabel = UILabel()
    private var leadingConstraint: NSLayoutConstraint?
    private var trailingConstraint: NSLayoutConstraint?
    /// Token used to discard stale fetches when the cell is reconfigured
    /// before the previous download finished.
    private var currentLoadID = UUID()

    /// Every block action the visitor presses. Forwarded by
    /// ``ChatlyMessagesView``; see ``ChatlyBlocksView/onAction`` for what this
    /// SDK can and cannot run itself.
    public var onBlockAction: ((ChatlyBlockAction) -> Void)? {
        get { blocksView.onAction }
        set { blocksView.onAction = newValue }
    }

    /// A pressed quick reply's value, to be sent as a visitor message.
    public var onQuickReply: ((String) -> Void)? {
        get { blocksView.onQuickReply }
        set { blocksView.onQuickReply = newValue }
    }

    public override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupViews()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        backgroundColor = .clear
        selectionStyle = .none

        bubble.translatesAutoresizingMaskIntoConstraints = false
        bubble.layer.cornerRadius = 14
        bubble.layer.cornerCurve = .continuous
        contentView.addSubview(bubble)

        bodyLabel.translatesAutoresizingMaskIntoConstraints = false
        bodyLabel.numberOfLines = 0
        bodyLabel.font = .systemFont(ofSize: 15)
        bubble.addSubview(bodyLabel)

        attachmentsStack.translatesAutoresizingMaskIntoConstraints = false
        attachmentsStack.axis = .vertical
        attachmentsStack.spacing = 6
        attachmentsStack.alignment = .fill
        attachmentsStack.distribution = .fill
        bubble.addSubview(attachmentsStack)

        bubble.addSubview(blocksView)

        metaLabel.translatesAutoresizingMaskIntoConstraints = false
        metaLabel.font = .systemFont(ofSize: 11)
        contentView.addSubview(metaLabel)

        let blocksTop = blocksView.topAnchor.constraint(equalTo: attachmentsStack.bottomAnchor)
        self.blocksTop = blocksTop

        NSLayoutConstraint.activate([
            bubble.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            bubble.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.78),

            bodyLabel.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 8),
            bodyLabel.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 12),
            bodyLabel.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -12),

            attachmentsStack.topAnchor.constraint(equalTo: bodyLabel.bottomAnchor, constant: 6),
            attachmentsStack.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 12),
            attachmentsStack.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -12),

            blocksTop,
            blocksView.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 12),
            blocksView.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -12),
            blocksView.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -8),

            metaLabel.topAnchor.constraint(equalTo: bubble.bottomAnchor, constant: 2),
            metaLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
        ])
    }

    public override func prepareForReuse() {
        super.prepareForReuse()
        currentLoadID = UUID()
        attachmentsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        // A reused cell must not show the previous row's card while the new
        // row's `configure` is still being called.
        blocksView.render(nil, theme: ChatlyTheme())
    }

    /// Renders `row` into the cell using the supplied `theme`.
    public func configure(with row: MessageRow, theme: ChatlyTheme) {
        bodyLabel.text = row.body
        bodyLabel.isHidden = row.body.isEmpty
        metaLabel.textColor = theme.mutedFg

        let isOutbound = row.authorType == .contact
        if isOutbound {
            bubble.backgroundColor = theme.primary
            bodyLabel.textColor = .white
            metaLabel.text = "You · \(Self.shortTime(row.createdAt))"
            metaLabel.textAlignment = .right
        } else {
            bubble.backgroundColor = theme.border
            bodyLabel.textColor = theme.fg
            metaLabel.text = "\(row.authorType.rawValue.capitalized) · \(Self.shortTime(row.createdAt))"
            metaLabel.textAlignment = .left
        }

        attachmentsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        attachmentsStack.isHidden = row.attachments.isEmpty
        for attachment in row.attachments {
            let view = makeAttachmentView(attachment: attachment, theme: theme, isOutbound: isOutbound)
            attachmentsStack.addArrangedSubview(view)
        }

        // `kind` is NOT the gate: the envelope is on the row or it is not, and
        // a message whose kind an older build fell back to `.text` can still
        // carry blocks. The reader answers with nothing when there is nothing.
        blocksTop?.constant = blocksView.render(row.blocks, theme: theme) ? 6 : 0

        leadingConstraint?.isActive = false
        trailingConstraint?.isActive = false
        if isOutbound {
            trailingConstraint = bubble.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16)
            trailingConstraint?.isActive = true
            metaLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16).isActive = true
        } else {
            leadingConstraint = bubble.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16)
            leadingConstraint?.isActive = true
            metaLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16).isActive = true
        }
    }

    private func makeAttachmentView(attachment: Attachment,
                                    theme: ChatlyTheme,
                                    isOutbound: Bool) -> UIView {
        if attachment.isImage, let url = URL(string: attachment.url) {
            let imageView = UIImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            imageView.layer.cornerRadius = 10
            imageView.layer.cornerCurve = .continuous
            imageView.backgroundColor = isOutbound
                ? UIColor.white.withAlphaComponent(0.15)
                : theme.bg
            imageView.heightAnchor.constraint(equalToConstant: 180).isActive = true
            loadImage(url: url, into: imageView)
            return imageView
        }
        return makeFileRow(attachment: attachment, theme: theme, isOutbound: isOutbound)
    }

    private func makeFileRow(attachment: Attachment, theme: ChatlyTheme, isOutbound: Bool) -> UIView {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = isOutbound
            ? UIColor.white.withAlphaComponent(0.15)
            : UIColor.black.withAlphaComponent(0.04)
        container.layer.cornerRadius = 8
        container.layer.cornerCurve = .continuous

        let icon = UIImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        if #available(iOS 13.0, *) {
            icon.image = UIImage(systemName: "doc")
        }
        icon.tintColor = isOutbound ? .white : theme.fg
        icon.contentMode = .scaleAspectFit
        container.addSubview(icon)

        let title = UILabel()
        title.translatesAutoresizingMaskIntoConstraints = false
        title.text = attachment.filename
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.textColor = isOutbound ? .white : theme.fg
        title.lineBreakMode = .byTruncatingMiddle
        container.addSubview(title)

        let subtitle = UILabel()
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        subtitle.text = Self.formatSize(attachment.sizeBytes)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = isOutbound ? UIColor.white.withAlphaComponent(0.75) : theme.mutedFg
        container.addSubview(subtitle)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 24),

            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            title.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            title.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),

            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            subtitle.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])
        return container
    }

    /// Fetch through ``ChatlyImageLoader``, which holds the one cache an
    /// attachment thumbnail and a card image now share. The staleness token
    /// stays here: only this cell reuses its views.
    private func loadImage(url: URL, into imageView: UIImageView) {
        let token = UUID()
        currentLoadID = token
        ChatlyImageLoader.load(url) { [weak self, weak imageView] image in
            guard let self = self, self.currentLoadID == token else { return }
            imageView?.image = image
        }
    }

    private static func formatSize(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    /// Best-effort ISO-8601 → short time formatter. Falls back to the raw
    /// string if parsing fails.
    private static func shortTime(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = formatter.date(from: iso) {
            return Self.timeFormatter.string(from: d)
        }
        let fallback = ISO8601DateFormatter()
        if let d = fallback.date(from: iso) {
            return Self.timeFormatter.string(from: d)
        }
        return iso
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()
}
#endif
