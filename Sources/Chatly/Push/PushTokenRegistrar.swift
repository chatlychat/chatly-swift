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
    /// `conversationId` key (see the worker's push handler).
    ///
    /// ── Why this goes through `replyTo` now ────────────────────────────────
    ///
    /// It used to build its own request: `{ conversationId, body, kind }` with
    /// an `Authorization: Bearer <session token>` header and no `publicId` or
    /// `visitorToken` in the body. Three things wrong with that, each on its
    /// own fatal — `widgetReplySchema` REQUIRES `publicId` and `visitorToken`,
    /// and the widget surface has never read an `Authorization` header. So
    /// every inline notification reply this SDK has ever sent was a 400, and
    /// the published docs listed the method as working.
    ///
    /// Routing it through the client's one choke point also buys it the
    /// `Idempotency-Key` and the stale-session replay, which matters more here
    /// than anywhere else: a push reply is the one call a visitor makes after
    /// the app has been in the background long enough for the token to have
    /// been refused.
    @discardableResult
    func handleNotificationReply(conversationId: String, text: String) async throws -> [String: Any] {
        let message = try await replyTo(conversationId: conversationId, body: text)
        return Chatly.rawObject(message)
    }
}
