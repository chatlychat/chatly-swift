import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

/// Rich-push notification category configuration for the agent app.
///
/// The backend push handler sets `aps.category = "CHATLY_MESSAGE"` on every
/// inbound-message push when the workspace has rich push enabled. iOS will
/// only render the inline reply field + buttons below if the host app has
/// previously registered a matching `UNNotificationCategory` with the
/// `UNUserNotificationCenter`.
///
/// Host apps must invoke ``Chatly/setNotificationCategories()`` once on
/// launch (typically from `application(_:didFinishLaunchingWithOptions:)`).
public enum ChatlyPushCategory {
    /// Identifier the backend embeds in `aps.category`. Do not change without
    /// coordinating with `apps/worker/src/handlers/push.ts`.
    public static let chatlyMessage = "CHATLY_MESSAGE"

    /// Action identifiers — host app delegates can branch on these in
    /// `userNotificationCenter(_:didReceive:withCompletionHandler:)`.
    public static let replyActionId = "CHATLY_REPLY"
    public static let dismissActionId = "CHATLY_DISMISS"
    public static let viewActionId = "CHATLY_VIEW"
}

public extension Chatly {
    /// Register Chatly's notification categories with the system notification
    /// center so action buttons render on incoming pushes.
    ///
    /// Idempotent — repeated calls overwrite the same category id. Safe to
    /// call before the user has accepted push permission; the categories are
    /// stored and applied once permission is granted.
    ///
    /// Includes three actions on the `CHATLY_MESSAGE` category:
    ///   * **Reply** — inline text input (`UNTextInputNotificationAction`),
    ///     does not require unlock.
    ///   * **View** — foreground action that brings the app forward.
    ///   * **Dismiss** — destructive, no-op on the backend.
    ///
    /// Note: APNS critical alerts are intentionally not requested here — they
    /// require a special Apple entitlement.
    func setNotificationCategories() {
        #if canImport(UserNotifications)
        let replyAction = UNTextInputNotificationAction(
            identifier: ChatlyPushCategory.replyActionId,
            title: "Reply",
            options: [.authenticationRequired],
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Type your reply..."
        )
        let viewAction = UNNotificationAction(
            identifier: ChatlyPushCategory.viewActionId,
            title: "View",
            options: [.foreground]
        )
        let dismissAction = UNNotificationAction(
            identifier: ChatlyPushCategory.dismissActionId,
            title: "Dismiss",
            options: [.destructive]
        )
        let category = UNNotificationCategory(
            identifier: ChatlyPushCategory.chatlyMessage,
            actions: [replyAction, viewAction, dismissAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
        #endif
    }

    /// Round-trip a reply action from a notification back to the API. Host
    /// apps should call this from
    /// `userNotificationCenter(_:didReceive:withCompletionHandler:)` when the
    /// `actionIdentifier` matches ``ChatlyPushCategory/replyActionId`` and
    /// the response is a `UNTextInputNotificationResponse`.
    ///
    /// The `conversationId` is read from the push payload's top-level
    /// `conversationId` key (see backend handler).
    @discardableResult
    func handleNotificationReply(conversationId: String, text: String) async throws -> [String: Any] {
        return try await sendNotificationReply(conversationId: conversationId, body: text)
    }

    private func sendNotificationReply(conversationId: String, body: String) async throws -> [String: Any] {
        // Reuse the existing widget message endpoint shape; an explicit
        // conversationId is included so the server routes to the existing
        // thread instead of opening a new one.
        return try await postJSON("/v1/widget/messages", body: [
            "conversationId": conversationId,
            "body": body,
            "kind": "text",
        ])
    }

    private func postJSON(_ path: String, body: [String: Any]) async throws -> [String: Any] {
        // Mirrors `Chatly.post(_:body:)` but kept here so the Push module can
        // remain self-contained. We deliberately do NOT capture the private
        // `config`/`session` from Chatly.swift — instead we resolve them via
        // a shared bootstrap helper.
        return try await ChatlyRequest.post(path, body: body)
    }
}

/// Internal helper that bridges the push extension back to the core Chatly
/// URLSession + base URL without exposing those as public surface. Kept
/// intentionally minimal — anything more complex belongs back in Chatly.swift.
enum ChatlyRequest {
    static func post(_ path: String, body: [String: Any]) async throws -> [String: Any] {
        let baseURL = ChatlyBootstrap.baseURL
        guard let base = baseURL else { throw ChatlyError.notConfigured }
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = ChatlyBootstrap.sessionToken {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ChatlyError.http(status: (resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}

/// Captures the configured base URL + contact session at SDK configure-time
/// so the Push module can use them without touching Chatly's private state.
public enum ChatlyBootstrap {
    public internal(set) static var baseURL: URL?
    public internal(set) static var sessionToken: String?
}
