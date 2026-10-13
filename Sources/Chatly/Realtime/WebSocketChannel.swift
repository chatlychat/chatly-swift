import Foundation

/// A live text-frame websocket.
///
/// An abstraction rather than `URLSessionWebSocketTask` directly, for one
/// reason: the tests that matter here are about **what the SDK sent**. A fake
/// transport that answers every route with a plausible reply agrees with the
/// bug — three sibling SDKs shipped a broken handshake under a green suite —
/// so the handshake frames have to be observable without a server, and that
/// means the socket has to be substitutable.
public protocol ChatlyWebSocketChannel: AnyObject {
    /// Sends one text frame. Fire-and-forget: a send failure surfaces as the
    /// socket closing, which is the only recovery this client has anyway.
    func send(_ text: String)
    /// Closes the socket and stops delivering callbacks.
    func close()
}

/// Opens ``ChatlyWebSocketChannel``s.
///
/// The handlers are passed in at open time rather than assigned afterwards:
/// a `URLSessionWebSocketTask` starts delivering as soon as it is resumed, so
/// an `onText` installed one statement later can miss the Engine.IO OPEN
/// frame — which is the frame the CONNECT packet has to be sent in reply to.
public protocol ChatlyWebSocketFactory {
    func open(
        url: URL,
        onText: @escaping (String) -> Void,
        onClose: @escaping (Error?) -> Void
    ) -> ChatlyWebSocketChannel
}

/// Production ``ChatlyWebSocketFactory``, on `URLSessionWebSocketTask`
/// (iOS 13+/macOS 10.15+, both below this package's floor).
public final class URLSessionWebSocketFactory: ChatlyWebSocketFactory {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func open(
        url: URL,
        onText: @escaping (String) -> Void,
        onClose: @escaping (Error?) -> Void
    ) -> ChatlyWebSocketChannel {
        return URLSessionWebSocketChannel(url: url, session: session, onText: onText, onClose: onClose)
    }
}

private final class URLSessionWebSocketChannel: ChatlyWebSocketChannel {
    private let task: URLSessionWebSocketTask
    private let lock = NSLock()
    private var onText: ((String) -> Void)?
    private var onClose: ((Error?) -> Void)?

    init(url: URL,
         session: URLSession,
         onText: @escaping (String) -> Void,
         onClose: @escaping (Error?) -> Void) {
        self.task = session.webSocketTask(with: url)
        self.onText = onText
        self.onClose = onClose
        task.resume()
        pump()
    }

    /// One `receive` at a time, re-armed after each frame. `URLSession`
    /// delivers these on its own delegate queue, so everything downstream of
    /// here is off the main thread — ``SocketTransport`` says so on its own
    /// callbacks and the bundled view controller bounces to main.
    private func pump() {
        task.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                self.fireClose(error)
            case .success(let message):
                switch message {
                case .string(let text):
                    self.fireText(text)
                case .data(let data):
                    // Engine.IO v4 only sends binary for binary attachments,
                    // which this gateway never does; decode as UTF-8 so a
                    // permessage-deflate oddity is not silently dropped.
                    if let text = String(data: data, encoding: .utf8) {
                        self.fireText(text)
                    }
                @unknown default:
                    break
                }
                self.pump()
            }
        }
    }

    private func fireText(_ text: String) {
        lock.lock()
        let handler = onText
        lock.unlock()
        handler?(text)
    }

    private func fireClose(_ error: Error?) {
        lock.lock()
        let handler = onClose
        onText = nil
        onClose = nil
        lock.unlock()
        handler?(error)
    }

    func send(_ text: String) {
        task.send(.string(text)) { _ in }
    }

    func close() {
        lock.lock()
        onText = nil
        onClose = nil
        lock.unlock()
        task.cancel(with: .goingAway, reason: nil)
    }
}
