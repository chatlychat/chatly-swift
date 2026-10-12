import Foundation
#if canImport(UIKit)
import UIKit

/// Full-screen widget surface presented by ``Chatly/Chatly/present(from:animated:)``.
///
/// Layout (top to bottom):
/// - Header with workspace name + close button
/// - Tab strip (Home / Messages / Help)
/// - Active tab content
/// - Composer (Messages tab only)
public final class ChatlyViewController: UIViewController {
    /// Tabs surfaced in the header strip.
    public enum Tab: Int, CaseIterable {
        case home
        case messages
        case help

        /// User-visible label.
        var title: String {
            switch self {
            case .home: return "Home"
            case .messages: return "Messages"
            case .help: return "Help"
            }
        }
    }

    private let theme: ChatlyTheme
    private var workspaceName: String

    private let headerView = UIView()
    private let titleLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private let segmented = UISegmentedControl(items: Tab.allCases.map { $0.title })
    private let homeView = UIView()
    private let messagesContainer = UIView()
    private let messagesView: ChatlyMessagesView
    private let composer: ChatlyComposerView
    private let helpView = UITableView(frame: .zero, style: .insetGrouped)

    private var conversationId: String?
    private var kbResults: [KbResult] = []
    private var searchTask: Task<Void, Never>?

    /// Designated initializer.
    public init(theme: ChatlyTheme, workspaceName: String = "Chatly") {
        self.theme = theme
        self.workspaceName = workspaceName
        self.messagesView = ChatlyMessagesView(theme: theme)
        self.composer = ChatlyComposerView(theme: theme)
        super.init(nibName: nil, bundle: nil)
    }

    public required init?(coder: NSCoder) {
        self.theme = ChatlyTheme()
        self.workspaceName = "Chatly"
        self.messagesView = ChatlyMessagesView(theme: theme)
        self.composer = ChatlyComposerView(theme: theme)
        super.init(coder: coder)
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = theme.bg
        navigationController?.setNavigationBarHidden(true, animated: false)

        installHeader()
        installSegmented()
        installContent()

        showTab(.home)
        loadInitialData()
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Route every realtime envelope through our handler, then open the
        // socket. Setting the closure before connecting avoids missing the
        // race with `replay.completed` after reconnect.
        Chatly.shared.onRealtimeEvent = { [weak self] envelope in
            // Transport delivers off-main; bounce to the main thread before
            // touching UIKit.
            DispatchQueue.main.async {
                self?.handleRealtimeEnvelope(envelope)
            }
        }
        _ = Chatly.shared.connectRealtime()
    }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        Chatly.shared.disconnectRealtime()
        Chatly.shared.onRealtimeEvent = nil
    }

    // MARK: Layout

    private func installHeader() {
        headerView.translatesAutoresizingMaskIntoConstraints = false
        headerView.backgroundColor = theme.bg
        view.addSubview(headerView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = workspaceName
        titleLabel.textColor = theme.fg
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        headerView.addSubview(titleLabel)

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        if #available(iOS 13.0, *) {
            closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        } else {
            closeButton.setTitle("Close", for: .normal)
        }
        closeButton.tintColor = theme.fg
        closeButton.addTarget(self, action: #selector(handleClose), for: .touchUpInside)
        headerView.addSubview(closeButton)

        let separator = UIView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.backgroundColor = theme.border
        headerView.addSubview(separator)

        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            headerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            headerView.heightAnchor.constraint(equalToConstant: 52),

            titleLabel.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 16),
            titleLabel.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),

            closeButton.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -12),
            closeButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 36),
            closeButton.heightAnchor.constraint(equalToConstant: 36),

            separator.heightAnchor.constraint(equalToConstant: 0.5),
            separator.leadingAnchor.constraint(equalTo: headerView.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: headerView.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: headerView.bottomAnchor),
        ])
    }

    private func installSegmented() {
        segmented.translatesAutoresizingMaskIntoConstraints = false
        segmented.selectedSegmentIndex = 0
        segmented.selectedSegmentTintColor = theme.primary
        segmented.setTitleTextAttributes([.foregroundColor: theme.mutedFg], for: .normal)
        segmented.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .selected)
        segmented.addTarget(self, action: #selector(handleTabChange), for: .valueChanged)
        view.addSubview(segmented)

        NSLayoutConstraint.activate([
            segmented.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: 12),
            segmented.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            segmented.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
        ])
    }

    private func installContent() {
        for v in [homeView, messagesContainer, helpView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
            NSLayoutConstraint.activate([
                v.topAnchor.constraint(equalTo: segmented.bottomAnchor, constant: 12),
                v.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                v.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
        }

        installHomeContent()
        installMessagesContent()
        installHelpContent()
    }

    private func installHomeContent() {
        homeView.backgroundColor = theme.bg
        let greeting = UILabel()
        greeting.translatesAutoresizingMaskIntoConstraints = false
        greeting.text = "Hi there. How can we help?"
        greeting.font = .systemFont(ofSize: 22, weight: .bold)
        greeting.textColor = theme.fg
        greeting.numberOfLines = 0
        homeView.addSubview(greeting)

        let startButton = UIButton(type: .system)
        startButton.translatesAutoresizingMaskIntoConstraints = false
        startButton.setTitle("Start a conversation", for: .normal)
        startButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        startButton.setTitleColor(.white, for: .normal)
        startButton.backgroundColor = theme.primary
        startButton.layer.cornerRadius = 12
        startButton.contentEdgeInsets = UIEdgeInsets(top: 12, left: 18, bottom: 12, right: 18)
        startButton.addTarget(self, action: #selector(handleStartFromHome), for: .touchUpInside)
        homeView.addSubview(startButton)

        NSLayoutConstraint.activate([
            greeting.topAnchor.constraint(equalTo: homeView.topAnchor, constant: 24),
            greeting.leadingAnchor.constraint(equalTo: homeView.leadingAnchor, constant: 16),
            greeting.trailingAnchor.constraint(equalTo: homeView.trailingAnchor, constant: -16),

            startButton.topAnchor.constraint(equalTo: greeting.bottomAnchor, constant: 24),
            startButton.leadingAnchor.constraint(equalTo: homeView.leadingAnchor, constant: 16),
        ])
    }

    private func installMessagesContent() {
        messagesContainer.backgroundColor = theme.bg
        messagesView.translatesAutoresizingMaskIntoConstraints = false
        composer.translatesAutoresizingMaskIntoConstraints = false
        messagesContainer.addSubview(messagesView)
        messagesContainer.addSubview(composer)

        NSLayoutConstraint.activate([
            messagesView.topAnchor.constraint(equalTo: messagesContainer.topAnchor),
            messagesView.leadingAnchor.constraint(equalTo: messagesContainer.leadingAnchor),
            messagesView.trailingAnchor.constraint(equalTo: messagesContainer.trailingAnchor),
            messagesView.bottomAnchor.constraint(equalTo: composer.topAnchor),

            composer.leadingAnchor.constraint(equalTo: messagesContainer.leadingAnchor),
            composer.trailingAnchor.constraint(equalTo: messagesContainer.trailingAnchor),
            composer.bottomAnchor.constraint(equalTo: messagesContainer.bottomAnchor),
        ])

        composer.presenter = self
        composer.onSend = { [weak self] text, attachments in
            self?.handleComposerSend(text, attachments: attachments)
        }
        composer.onUploadRequested = { data, filename, mimeType in
            return try await Chatly.shared.uploadAttachment(data, filename: filename, mimeType: mimeType)
        }
    }

    private func installHelpContent() {
        helpView.backgroundColor = theme.bg
        helpView.dataSource = self
        helpView.delegate = self
        helpView.register(UITableViewCell.self, forCellReuseIdentifier: "kb.cell")
    }

    // MARK: Data

    private func loadInitialData() {
        Task { [weak self] in
            guard let self = self else { return }
            do {
                let init_ = try await Chatly.shared.initSession(identity: nil)
                await MainActor.run {
                    self.workspaceName = init_.workspace.name
                    self.titleLabel.text = init_.workspace.name
                    // [Chatly.connectRealtime()] depends on the cached contact
                    // id set by [initSession]. Retry once now that we have it
                    // in case the [viewDidAppear] attempt was a no-op.
                    if Chatly.shared.onRealtimeEvent != nil {
                        _ = Chatly.shared.connectRealtime()
                    }
                }
                let convs = try await Chatly.shared.listConversations(limit: 1)
                if let first = convs.first {
                    self.conversationId = first.id
                    let messages = try await Chatly.shared.listMessages(conversationId: first.id, limit: 50)
                    await MainActor.run {
                        self.messagesView.setMessages(messages)
                    }
                }
            } catch {
                // Silently degrade — the UI still functions for a fresh visitor.
            }
        }
    }

    // MARK: Realtime

    /// Decodable shape we expect inside a `message.created` envelope. Fields
    /// match `realtime/messageCreatedPayloadSchema` on the server.
    private struct RealtimeMessagePayload: Decodable {
        let id: String
        let conversationId: String
        let authorType: MessageRow.AuthorType
        let body: String
        let attachments: [Attachment]?
        let createdAt: String
    }

    /// Dispatches a realtime envelope to the right local handler.
    ///
    /// Only `message.created`, `typing.start`, and `typing.stop` are handled;
    /// everything else is ignored to keep the UI deterministic across SDK
    /// versions (the transport itself decodes unknown types via
    /// ``RealtimeEventType/unknown(_:)``).
    private func handleRealtimeEnvelope(_ envelope: RealtimeEnvelope) {
        switch envelope.type {
        case .messageCreated:
            guard let payload = envelope.decodePayload(as: RealtimeMessagePayload.self) else {
                return
            }
            // Only mutate the open conversation. Other conversations will
            // refresh next time `listConversations` runs.
            guard payload.conversationId == conversationId else { return }
            let row = MessageRow(
                id: payload.id,
                authorType: payload.authorType,
                kind: .text,
                body: payload.body,
                attachments: payload.attachments ?? [],
                createdAt: payload.createdAt
            )
            messagesView.append(row)
        case .typingStart, .typingStop:
            // Typing indicator UI is not yet rendered — accept the events so
            // we can hook it up later without changing the dispatch contract.
            break
        default:
            break
        }
    }

    private func handleComposerSend(_ text: String, attachments: [Attachment]) {
        let kind: MessageRow.Kind = text.isEmpty && !attachments.isEmpty ? .attachmentOnly : .text
        if let cid = conversationId {
            Task {
                _ = try? await Chatly.shared.replyTo(conversationId: cid,
                                                    body: text,
                                                    attachments: attachments.isEmpty ? nil : attachments)
            }
            let optimistic = MessageRow(
                id: UUID().uuidString,
                authorType: .contact,
                kind: kind,
                body: text,
                attachments: attachments,
                createdAt: Self.nowIso()
            )
            messagesView.append(optimistic)
            return
        }
        Task { [weak self] in
            guard let self = self else { return }
            do {
                let started = try await Chatly.shared.startConversation(
                    body: text,
                    attachments: attachments.isEmpty ? nil : attachments
                )
                self.conversationId = started.conversation.id
                let optimistic = MessageRow(
                    id: started.message.id,
                    authorType: .contact,
                    kind: kind,
                    body: started.message.body,
                    attachments: attachments,
                    createdAt: started.message.createdAt
                )
                await MainActor.run { self.messagesView.append(optimistic) }
            } catch {
                // No-op — user can retry.
            }
        }
    }

    // MARK: Tabs

    private func showTab(_ tab: Tab) {
        homeView.isHidden = tab != .home
        messagesContainer.isHidden = tab != .messages
        helpView.isHidden = tab != .help
    }

    @objc private func handleTabChange() {
        guard let tab = Tab(rawValue: segmented.selectedSegmentIndex) else { return }
        showTab(tab)
    }

    @objc private func handleClose() {
        dismiss(animated: true)
    }

    @objc private func handleStartFromHome() {
        segmented.selectedSegmentIndex = Tab.messages.rawValue
        showTab(.messages)
    }

    private static func nowIso() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date())
    }
}

// MARK: - Help tab data source

extension ChatlyViewController: UITableViewDataSource, UITableViewDelegate {
    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        max(kbResults.count, 1)
    }

    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "kb.cell", for: indexPath)
        if kbResults.isEmpty {
            cell.textLabel?.text = "Search the help center"
            cell.textLabel?.textColor = theme.mutedFg
            cell.detailTextLabel?.text = nil
            cell.accessoryType = .none
        } else {
            let r = kbResults[indexPath.row]
            cell.textLabel?.text = r.title
            cell.textLabel?.textColor = theme.fg
            cell.detailTextLabel?.text = r.excerpt
            cell.accessoryType = .disclosureIndicator
        }
        return cell
    }

    public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.row < kbResults.count else { return }
        let slug = kbResults[indexPath.row].slug
        Task {
            _ = try? await Chatly.shared.getKbArticle(slug: slug)
            // Article rendering is left to host apps for now.
        }
    }
}
#endif
