# Chatly iOS SDK (Swift)

A dependency-free Swift client for Chatly's public `/v1/widget/*` surface:
visitor session, identity, events, conversations, attachments, knowledge base,
push, and a live Socket.IO connection. iOS 14+, macOS 12+, Swift 5.7+,
`Foundation` only.

```swift
import Chatly

Chatly.shared.configure(.init(channelPublicId: "CH_abc123"))

try await Chatly.shared.identify(externalId: "u-42", email: "jamie@acme.io")
try await Chatly.shared.track("checkout.completed", properties: ["orderId": "O-7"])
try await Chatly.shared.send("Hi!")
```

`baseURL` defaults to `https://api.chatlychat.com`, so there is no host to
pass.

## Chat

```swift
let started = try await Chatly.shared.startConversation(body: "My order is late")

let messages = try await Chatly.shared.listMessages(conversationId: started.conversation.id)
try await Chatly.shared.replyTo(conversationId: started.conversation.id, body: "Any update?")
```

`send(_:)` is the short form: it opens a conversation when there is not one
and continues the one it opened.

### Attachments

Three steps, and the client does all three — presign, PUT the raw bytes, hand
back the `Attachment` to put on a message:

```swift
let attachment = try await Chatly.shared.uploadAttachment(
    pngData, filename: "receipt.png", mimeType: "image/png"
)
try await Chatly.shared.replyTo(
    conversationId: conversationId, body: "", attachments: [attachment]
)
```

## Realtime

```swift
Chatly.shared.onRealtimeEvent = { envelope in
    // Delivered OFF the main thread.
    DispatchQueue.main.async { render(envelope) }
}
Chatly.shared.connectRealtime(conversationId: conversationId)
```

Two things worth knowing, because both have been got wrong:

- The socket does **not** use the session token from `init`. It uses a
  conversation-scoped token minted at `POST /v1/widget/realtime/token`, and the
  client mints it for you — on **every** connection attempt, so a reconnect
  after the token's 1h lifetime gets a fresh one instead of silently replaying
  a dead credential.
- `connectRealtime` returns `false`, and does nothing, when there is no
  conversation. The token names one conversation, so there is nothing to
  subscribe to before the visitor has started a thread. Switching
  conversations re-mints and reconnects.

`markRead(upToMessageId:)` and `setTyping(_:)` are the two things a visitor may
send back.

## Knowledge base

```swift
let hits = try await Chatly.shared.searchKb(query: "refund")      // "" = browse
let article = try await Chatly.shared.getKbArticle(slug: hits[0].slug)
```

## Push

Call `registerPushToken(_:)` from
`application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`, and
`setNotificationCategories()` once at launch for the rich-push action buttons.
`handleNotificationReply(conversationId:text:)` sends an inline reply.

## UIKit views

`ChatlyViewController` is a three-tab widget surface (Home / Messages / Help)
dressed by `ChatlyTheme`. It is UIKit only; there are no SwiftUI views. Set
`onSelectHelpArticle` to render a knowledge-base article — the package has no
reader view of its own.

## Install

Swift Package Manager:

```
https://github.com/chatlychat/chatly-swift.git
```

## Contributing

```
swift test     # unit tests AND an iOS cross-compile — see below
```

A third of this package is inside `#if canImport(UIKit)`, which is **false**
when `swift build` runs on macOS. For most of this package's life that meant
`ChatlyViewController` and its views were excluded from every build anybody
ran, and they had accumulated 9 compile errors nothing could see.

`swift test` now cross-compiles the whole package for iOS as one of its cases
(`IOSBuildTests`), via:

```
./Scripts/ios-build.sh
```

Run that directly when the test tells you it failed. It skips — loudly, and
only — on a machine with no iOS SDK.

---

## About this repository

This is a **mirror**. `chatly-swift` is built from a private monorepo where the rest
of the platform, its migrations and its contract checks live, so a pull request here
cannot be merged directly — but a patch is still the fastest way to get something
fixed and we will port it with attribution.

What you can do here: read the source, run the tests, open an issue, or open a PR
and we will treat the diff as the proposal.

Issues: https://github.com/chatlychat/chatly-swift/issues · Docs: https://chatlychat.com/docs
