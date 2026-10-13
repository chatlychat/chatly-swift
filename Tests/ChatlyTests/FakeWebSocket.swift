import Foundation
import XCTest
@testable import Chatly

/// A websocket that connects to nothing and records every frame the SDK sent.
///
/// ── Why the fake is on the SEND side ───────────────────────────────────────
///
/// A fake that answers every route with whatever the client asked for agrees
/// with the bug, and that trap has cost this repository a day twice. Every
/// defect this file exists to pin is in the REQUEST: the handshake omitting
/// `kind: "visitor"`, the handshake carrying the long-lived session token
/// instead of a minted realtime one, and a reconnect replaying a frozen
/// credential. None of those is visible in a response, so none of them can be
/// faked away — the assertions are on ``frames``.
final class FakeSocket: ChatlyWebSocketChannel {
    let url: URL
    private let lock = NSLock()
    private var sent: [String] = []
    private var onText: ((String) -> Void)?
    private var onClose: ((Error?) -> Void)?
    private var closed = false

    init(url: URL, onText: @escaping (String) -> Void, onClose: @escaping (Error?) -> Void) {
        self.url = url
        self.onText = onText
        self.onClose = onClose
    }

    /// Every text frame the SDK has put on this socket, in order.
    var frames: [String] {
        lock.lock()
        defer { lock.unlock() }
        return sent
    }

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    func send(_ text: String) {
        lock.lock()
        sent.append(text)
        lock.unlock()
    }

    /// Matches the production channel: closing stops delivery, so a frame that
    /// was already in flight cannot reach a transport generation that has
    /// moved on.
    func close() {
        lock.lock()
        closed = true
        onText = nil
        onClose = nil
        lock.unlock()
    }

    /// Server → client.
    func deliver(_ text: String) {
        lock.lock()
        let handler = onText
        lock.unlock()
        handler?(text)
    }

    /// The socket dies — a network blip, or the far end hanging up.
    func drop(_ error: Error? = nil) {
        lock.lock()
        let handler = onClose
        onText = nil
        onClose = nil
        closed = true
        lock.unlock()
        handler?(error)
    }

    /// The Engine.IO OPEN frame, which is what the CONNECT packet is a reply to.
    static let openFrame = #"0{"sid":"abc","upgrades":[],"pingInterval":25000,"pingTimeout":20000}"#
}

final class FakeSocketFactory: ChatlyWebSocketFactory {
    private let lock = NSLock()
    private var opened: [FakeSocket] = []

    var sockets: [FakeSocket] {
        lock.lock()
        defer { lock.unlock() }
        return opened
    }

    func open(
        url: URL,
        onText: @escaping (String) -> Void,
        onClose: @escaping (Error?) -> Void
    ) -> ChatlyWebSocketChannel {
        let socket = FakeSocket(url: url, onText: onText, onClose: onClose)
        lock.lock()
        opened.append(socket)
        lock.unlock()
        return socket
    }
}

// MARK: - Frame readers

/// The `auth` object out of a `40{…}` CONNECT frame, or `nil` when the frame
/// is not one.
func handshakeAuth(_ frame: String) -> [String: Any]? {
    guard frame.hasPrefix("40") else { return nil }
    let json = String(frame.dropFirst(2))
    guard let data = json.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

/// `["<name>", <payload>]` out of a `42[…]` EVENT frame.
func emittedEvent(_ frame: String) -> (name: String, payload: [String: Any])? {
    guard frame.hasPrefix("42") else { return nil }
    let json = String(frame.dropFirst(2))
    guard let data = json.data(using: .utf8),
          let array = (try? JSONSerialization.jsonObject(with: data)) as? [Any],
          let name = array.first as? String else { return nil }
    return (name, (array.count > 1 ? array[1] as? [String: Any] : nil) ?? [:])
}

/// Spin the run loop until `condition` holds, or fail.
///
/// The transport serialises its work on a private queue and `connect()` is
/// driven from a `Task`, so "the SDK has sent the handshake" is not true the
/// instant a call returns.
///
/// `async` + `Task.sleep`, not `RunLoop.current.run(until:)`. `RunLoop.current`
/// and `run(until:)` are both `noasync`, and every caller here is an async
/// test — Swift 5's checking reports "unavailable from asynchronous contexts
/// … this is an error in Swift 6". Swift 6.3 does not warn, so it is
/// invisible locally and only the mirror CI's older toolchain sees it.
///
/// Sleeping also yields the cooperative pool, which spinning a run loop on the
/// calling thread does not — so the transport's own `Task` can actually make
/// progress while this waits, which is the entire point of the helper.
func waitUntil(_ description: String,
               timeout: TimeInterval = 2,
               file: StaticString = #filePath,
               line: UInt = #line,
               _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline {
            return XCTFail("timed out waiting for \(description)", file: file, line: line)
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}
