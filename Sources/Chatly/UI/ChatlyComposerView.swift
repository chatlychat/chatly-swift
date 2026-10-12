import Foundation
#if canImport(UIKit)
import UIKit
import UniformTypeIdentifiers

/// Bottom-of-screen composer: a `UITextView` that grows with content, a
/// paperclip attachment button, and a circular send button.
///
/// The hosting view controller is responsible for forwarding ``onSend`` to the
/// REST layer and presenting any pickers requested via ``onPickAttachment``;
/// this view contains no networking.
public final class ChatlyComposerView: UIView, UITextViewDelegate,
    UIDocumentPickerDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    /// Invoked when the user taps send. The composer is cleared automatically
    /// before the closure runs. `attachments` is non-empty only when the user
    /// staged one or more files via the paperclip button.
    public var onSend: ((String, [Attachment]) -> Void)?
    /// Invoked when the text view first gains a non-empty value, and again
    /// when it transitions back to empty.
    public var onTypingChange: ((Bool) -> Void)?
    /// Called when the user staged a file/image and the composer needs the
    /// host to perform the upload. Hosts should hand back the resulting
    /// ``Attachment`` (or throw); the composer will install the chip on
    /// success and surface a failure label on error.
    public var onUploadRequested: ((_ data: Data,
                                    _ filename: String,
                                    _ mimeType: String) async throws -> Attachment)?

    private let textView = UITextView()
    private let sendButton = UIButton(type: .system)
    private let attachButton = UIButton(type: .system)
    private let placeholder = UILabel()
    private let chipStack = UIStackView()
    private var heightConstraint: NSLayoutConstraint?
    private var wasTyping = false
    private var theme: ChatlyTheme
    private var stagedAttachments: [Attachment] = []
    /// Weakly held so the composer doesn't retain its host while a picker is
    /// presented modally.
    public weak var presenter: UIViewController?

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
        layer.borderWidth = 0.5
        layer.borderColor = theme.border.cgColor

        chipStack.translatesAutoresizingMaskIntoConstraints = false
        chipStack.axis = .horizontal
        chipStack.spacing = 6
        chipStack.alignment = .center
        chipStack.distribution = .fill
        chipStack.isHidden = true
        addSubview(chipStack)

        attachButton.translatesAutoresizingMaskIntoConstraints = false
        if #available(iOS 13.0, *) {
            attachButton.setImage(UIImage(systemName: "paperclip"), for: .normal)
        } else {
            attachButton.setTitle("+", for: .normal)
        }
        attachButton.tintColor = theme.primary
        attachButton.accessibilityLabel = "Attach file"
        attachButton.addTarget(self, action: #selector(handleAttachTap), for: .touchUpInside)
        addSubview(attachButton)

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.font = .systemFont(ofSize: 15)
        textView.textColor = theme.fg
        textView.backgroundColor = .clear
        textView.delegate = self
        textView.isScrollEnabled = false
        textView.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        addSubview(textView)

        placeholder.translatesAutoresizingMaskIntoConstraints = false
        placeholder.text = "Type a message…"
        placeholder.textColor = theme.mutedFg
        placeholder.font = textView.font
        addSubview(placeholder)

        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.setTitle("Send", for: .normal)
        sendButton.tintColor = theme.primary
        sendButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        sendButton.addTarget(self, action: #selector(handleSend), for: .touchUpInside)
        addSubview(sendButton)

        let height = textView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        height.isActive = true
        heightConstraint = height

        NSLayoutConstraint.activate([
            chipStack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            chipStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            chipStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),

            attachButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            attachButton.widthAnchor.constraint(equalToConstant: 36),
            attachButton.heightAnchor.constraint(equalToConstant: 36),
            attachButton.centerYAnchor.constraint(equalTo: textView.centerYAnchor),

            textView.topAnchor.constraint(equalTo: chipStack.bottomAnchor, constant: 6),
            textView.leadingAnchor.constraint(equalTo: attachButton.trailingAnchor, constant: 4),
            textView.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -8),
            textView.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -8),

            placeholder.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 12),
            placeholder.topAnchor.constraint(equalTo: textView.topAnchor, constant: 10),

            sendButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            sendButton.centerYAnchor.constraint(equalTo: textView.centerYAnchor),
            sendButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 48),
        ])
    }

    /// Re-applies a theme, e.g. after a system appearance change.
    public func apply(theme: ChatlyTheme) {
        self.theme = theme
        backgroundColor = theme.bg
        layer.borderColor = theme.border.cgColor
        textView.textColor = theme.fg
        placeholder.textColor = theme.mutedFg
        sendButton.tintColor = theme.primary
        attachButton.tintColor = theme.primary
    }

    @objc private func handleSend() {
        let trimmed = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = stagedAttachments
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        textView.text = ""
        placeholder.isHidden = false
        stagedAttachments = []
        renderChips()
        onSend?(trimmed, attachments)
        updateTyping(isTyping: false)
    }

    @objc private func handleAttachTap() {
        let alert = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "Photo Library", style: .default) { [weak self] _ in
            self?.presentImagePicker()
        })
        alert.addAction(UIAlertAction(title: "Browse Files", style: .default) { [weak self] _ in
            self?.presentDocumentPicker()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.sourceView = attachButton
            popover.sourceRect = attachButton.bounds
        }
        presenter?.present(alert, animated: true)
    }

    private func presentImagePicker() {
        guard let presenter = presenter else { return }
        let picker = UIImagePickerController()
        picker.sourceType = .photoLibrary
        picker.delegate = self
        presenter.present(picker, animated: true)
    }

    private func presentDocumentPicker() {
        guard let presenter = presenter else { return }
        let picker: UIDocumentPickerViewController
        if #available(iOS 14.0, *) {
            picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        } else {
            picker = UIDocumentPickerViewController(documentTypes: ["public.item"], in: .import)
        }
        picker.delegate = self
        picker.allowsMultipleSelection = false
        presenter.present(picker, animated: true)
    }

    private func updateTyping(isTyping: Bool) {
        guard isTyping != wasTyping else { return }
        wasTyping = isTyping
        onTypingChange?(isTyping)
    }

    /// Stages an upload after a successful pick. Renders a removable chip
    /// immediately and triggers the upload via ``onUploadRequested``; the
    /// chip is updated in place when the upload completes.
    private func stageUpload(data: Data, filename: String, mimeType: String) {
        guard let onUpload = onUploadRequested else { return }
        let placeholderChip = UIView()
        installChipView(placeholderChip, label: filename, spinner: true)
        renderChips()
        Task { [weak self] in
            do {
                let attachment = try await onUpload(data, filename, mimeType)
                await MainActor.run {
                    guard let self = self else { return }
                    self.stagedAttachments.append(attachment)
                    self.renderChips()
                }
            } catch {
                await MainActor.run {
                    placeholderChip.removeFromSuperview()
                    self?.renderChips()
                }
            }
        }
    }

    private func renderChips() {
        chipStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for attachment in stagedAttachments {
            let chip = UIView()
            installChipView(chip, label: attachment.filename, spinner: false, onRemove: { [weak self] in
                guard let self = self else { return }
                self.stagedAttachments.removeAll { $0.id == attachment.id }
                self.renderChips()
            })
        }
        chipStack.isHidden = chipStack.arrangedSubviews.isEmpty
    }

    private func installChipView(_ chip: UIView,
                                 label text: String,
                                 spinner: Bool,
                                 onRemove: (() -> Void)? = nil) {
        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.backgroundColor = theme.border
        chip.layer.cornerRadius = 10
        chip.layer.cornerCurve = .continuous

        let title = UILabel()
        title.translatesAutoresizingMaskIntoConstraints = false
        title.text = text
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.textColor = theme.fg
        title.lineBreakMode = .byTruncatingMiddle
        chip.addSubview(title)

        var trailingAnchorView: UIView = title
        if spinner {
            let activity = UIActivityIndicatorView(style: .medium)
            activity.translatesAutoresizingMaskIntoConstraints = false
            activity.startAnimating()
            chip.addSubview(activity)
            NSLayoutConstraint.activate([
                activity.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 6),
                activity.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
                activity.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -8),
            ])
            trailingAnchorView = activity
        } else if let onRemove = onRemove {
            let removeButton = UIButton(type: .system)
            removeButton.translatesAutoresizingMaskIntoConstraints = false
            if #available(iOS 13.0, *) {
                removeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
            } else {
                removeButton.setTitle("x", for: .normal)
            }
            removeButton.tintColor = theme.mutedFg
            removeButton.addAction(UIAction { _ in onRemove() }, for: .touchUpInside)
            chip.addSubview(removeButton)
            NSLayoutConstraint.activate([
                removeButton.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 4),
                removeButton.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
                removeButton.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -4),
                removeButton.widthAnchor.constraint(equalToConstant: 22),
                removeButton.heightAnchor.constraint(equalToConstant: 22),
            ])
            trailingAnchorView = removeButton
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 8),
            title.topAnchor.constraint(equalTo: chip.topAnchor, constant: 5),
            title.bottomAnchor.constraint(equalTo: chip.bottomAnchor, constant: -5),
            title.widthAnchor.constraint(lessThanOrEqualToConstant: 160),
            chip.heightAnchor.constraint(equalToConstant: 28),
        ])
        // Guard against unused-variable warnings when the chip is spinner-only.
        _ = trailingAnchorView
        chipStack.addArrangedSubview(chip)
        chipStack.isHidden = false
    }

    // MARK: UITextViewDelegate

    public func textViewDidChange(_ textView: UITextView) {
        placeholder.isHidden = !textView.text.isEmpty
        updateTyping(isTyping: !textView.text.isEmpty)
    }

    // MARK: UIDocumentPickerDelegate

    public func documentPicker(_ controller: UIDocumentPickerViewController,
                               didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                url.stopAccessingSecurityScopedResource()
            }
        }
        guard let data = try? Data(contentsOf: url) else { return }
        let mime = Self.mimeType(for: url)
        stageUpload(data: data, filename: url.lastPathComponent, mimeType: mime)
    }

    // MARK: UIImagePickerControllerDelegate

    public func imagePickerController(_ picker: UIImagePickerController,
                                      didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        picker.dismiss(animated: true)
        guard let image = info[.originalImage] as? UIImage,
              let data = image.jpegData(compressionQuality: 0.85) else {
            return
        }
        let filename: String
        if let url = info[.imageURL] as? URL {
            filename = url.lastPathComponent
        } else {
            filename = "photo-\(Int(Date().timeIntervalSince1970)).jpg"
        }
        stageUpload(data: data, filename: filename, mimeType: "image/jpeg")
    }

    public func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
    }

    /// Best-effort MIME lookup from a file URL using UTType when available.
    private static func mimeType(for url: URL) -> String {
        if #available(iOS 14.0, *) {
            if let type = UTType(filenameExtension: url.pathExtension),
               let mime = type.preferredMIMEType {
                return mime
            }
        }
        return "application/octet-stream"
    }
}
#endif
