import Foundation
#if canImport(UIKit)
import UIKit

/// Scrollable list of chat bubbles.
///
/// A thin `UIView` wrapper around a `UITableView` registered with
/// ``ChatlyMessageCell``. The container view controller owns the data; this
/// view just renders what it is handed.
public final class ChatlyMessagesView: UIView, UITableViewDataSource, UITableViewDelegate {
    /// The underlying table view, exposed for scroll-to-bottom etc.
    public let tableView = UITableView(frame: .zero, style: .plain)

    private var messages: [MessageRow] = []
    private var theme: ChatlyTheme

    /// Creates the view with the supplied visual theme.
    public init(theme: ChatlyTheme) {
        self.theme = theme
        super.init(frame: .zero)
        setup()
    }

    public required init?(coder: NSCoder) {
        self.theme = ChatlyTheme()
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = theme.bg
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = theme.bg
        tableView.separatorStyle = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(ChatlyMessageCell.self, forCellReuseIdentifier: ChatlyMessageCell.reuseIdentifier)
        tableView.estimatedRowHeight = 64
        tableView.rowHeight = UITableView.automaticDimension
        tableView.keyboardDismissMode = .interactive
        addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: topAnchor),
            tableView.leadingAnchor.constraint(equalTo: leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// Replaces the current list and reloads.
    public func setMessages(_ rows: [MessageRow]) {
        self.messages = rows
        tableView.reloadData()
        scrollToBottom(animated: false)
    }

    /// Appends one message and animates to the bottom. Returns `false` when
    /// the row is a duplicate of an existing id and was therefore ignored —
    /// callers can use this to short-circuit follow-on side effects.
    @discardableResult
    public func append(_ row: MessageRow) -> Bool {
        if messages.contains(where: { $0.id == row.id }) { return false }
        messages.append(row)
        let idx = IndexPath(row: messages.count - 1, section: 0)
        let animation: UITableView.RowAnimation
        switch row.authorType {
        case .agent, .bot: animation = .left
        default: animation = .right
        }
        tableView.insertRows(at: [idx], with: animation)
        scrollToBottom(animated: true)
        return true
    }

    /// Updates the theme and re-renders.
    public func apply(theme: ChatlyTheme) {
        self.theme = theme
        backgroundColor = theme.bg
        tableView.backgroundColor = theme.bg
        tableView.reloadData()
    }

    /// Scrolls the last row into view. No-op when the list is empty.
    public func scrollToBottom(animated: Bool) {
        guard !messages.isEmpty else { return }
        let idx = IndexPath(row: messages.count - 1, section: 0)
        tableView.scrollToRow(at: idx, at: .bottom, animated: animated)
    }

    // MARK: UITableViewDataSource

    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        messages.count
    }

    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: ChatlyMessageCell.reuseIdentifier,
                                                 for: indexPath)
        guard let chatCell = cell as? ChatlyMessageCell else { return cell }
        chatCell.configure(with: messages[indexPath.row], theme: theme)
        return chatCell
    }
}
#endif
