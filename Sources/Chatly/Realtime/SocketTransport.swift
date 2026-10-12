import Foundation
#if canImport(SocketIO)
import SocketIO
#endif

/// Connection lifecycle reported by ``SocketTransport``.
public enum SocketTransportState: Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting
    case errored(String)
}

/// Socket.IO transport that streams realtime envelopes to the SDK.
///
/// Connects to `${apiHost}/realtime`, subscribes to a per-visitor channel
/// (`visitor:{contactId}`) and forwards every inbound envelope to a closure.
/// Supports replay-from-cursor via ``lastEventId``.
public final class SocketTransport {
    /// The visitor channel currently subscribed to, if any.
    public private(set) var channel: String?
    /// Cursor for the next reconnect. Updated as envelopes arrive.
    public private(set) var lastEventId: String?
    /// Last reported transport state.
    public private(set) var state: SocketTransportState = .disconnected

    /// Called on every decoded envelope.
    public var onEnvelope: ((RealtimeEnvelope) -> Void)?
    /// Called on every state change.
    public var onState: ((SocketTransportState) -> Void)?

    private let apiHost: URL
    private let authToken: String?

    #if canImport(SocketIO)
    private var manager: SocketManager?
    private var socket: SocketIOClient?
    #endif

    /// Creates a transport pointed at `apiHost` (e.g. `https://api.chatly.io`).
    /// The path `/realtime` is appended internally.
    public init(apiHost: URL, authToken: String? = nil) {
        self.apiHost = apiHost
        self.authToken = authToken
    }

    /// Opens the socket and subscribes to `visitor:{contactId}`.
    ///
    /// - Parameters:
    ///   - contactId: the visitor's contact id (returned from `init`).
    ///   - lastEventId: optional replay cursor; the server resends events with
    ///     id > cursor before live delivery resumes.
    public func connect(contactId: String, lastEventId: String? = nil) {
        let channelName = "visitor:\(contactId)"
        self.channel = channelName
        if let cursor = lastEventId { self.lastEventId = cursor }
        updateState(.connecting)

        #if canImport(SocketIO)
        let url = apiHost
        var config: SocketIOClientConfiguration = [
            .log(false),
            .compress,
            .path("/realtime"),
            .reconnects(true),
            .forceWebsockets(true),
        ]
        if let token = authToken {
            config.insert(.extraHeaders(["Authorization": "Bearer \(token)"]))
            config.insert(.connectParams(["token": token]))
        }
        let manager = SocketManager(socketURL: url, config: config)
        let socket = manager.defaultSocket
        self.manager = manager
        self.socket = socket

        socket.on(clientEvent: .connect) { [weak self] _, _ in
            guard let self = self else { return }
            self.updateState(.connected)
            self.sendSubscribe(channel: channelName)
        }
        socket.on(clientEvent: .disconnect) { [weak self] _, _ in
            self?.updateState(.disconnected)
        }
        socket.on(clientEvent: .reconnect) { [weak self] _, _ in
            self?.updateState(.reconnecting)
        }
        socket.on(clientEvent: .error) { [weak self] data, _ in
            let msg = (data.first as? String) ?? "socket error"
            self?.updateState(.errored(msg))
        }
        socket.on("envelope") { [weak self] data, _ in
            self?.handleIncoming(data)
        }

        socket.connect()
        #else
        updateState(.errored("SocketIO unavailable"))
        #endif
    }

    /// Tears down the socket. Safe to call when already disconnected.
    public func disconnect() {
        #if canImport(SocketIO)
        socket?.disconnect()
        socket = nil
        manager = nil
        #endif
        channel = nil
        updateState(.disconnected)
    }

    /// Emits a typed envelope back to the server (typing, presence, etc.).
    public func emit(_ envelope: RealtimeEnvelope) {
        #if canImport(SocketIO)
        guard let socket = socket else { return }
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        guard let obj = try? JSONSerialization.jsonObject(with: data) else { return }
        socket.emit("envelope", obj as Any)
        #endif
    }

    // MARK: - Private

    private func sendSubscribe(channel: String) {
        let payload: [String: Any] = [
            "channels": [channel],
            "lastEventId": lastEventId as Any,
        ].compactMapValues { ($0 is NSNull) ? nil : $0 }

        #if canImport(SocketIO)
        socket?.emit("subscribe", payload)
        #endif
    }

    private func handleIncoming(_ data: [Any]) {
        guard let first = data.first else { return }
        let json: Data?
        if let dict = first as? [String: Any] {
            json = try? JSONSerialization.data(withJSONObject: dict)
        } else if let s = first as? String, let raw = s.data(using: .utf8) {
            json = raw
        } else {
            json = nil
        }
        guard let payload = json else { return }
        guard let envelope = try? JSONDecoder().decode(RealtimeEnvelope.self, from: payload) else {
            return
        }
        lastEventId = envelope.id
        onEnvelope?(envelope)
    }

    private func updateState(_ next: SocketTransportState) {
        state = next
        onState?(next)
    }
}
