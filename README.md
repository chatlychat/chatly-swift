# Chatly iOS SDK (Swift)

```swift
import Chatly

Chatly.shared.configure(.init(
    channelPublicId: "CH_abc123",
    baseURL: URL(string: "https://api.chatlychat.com")!,
    appURL: URL(string: "https://app.chatlychat.com")!
))

try await Chatly.shared.identify(externalId: "u-42", email: "jamie@acme.io")
try await Chatly.shared.track("checkout.completed", properties: ["orderId": "O-7"])
try await Chatly.shared.send("Hi!")
```

To enable push notifications, call `registerPushToken(_ deviceToken: Data)` from
`application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.

Install via Swift Package Manager:

```
https://github.com/chatly/sdk-swift.git
```

---

## About this repository

This is a **mirror**. `chatly-swift` is built from a private monorepo where the rest
of the platform, its migrations and its contract checks live, so a pull request here
cannot be merged directly — but a patch is still the fastest way to get something
fixed and we will port it with attribution.

What you can do here: read the source, run the tests, open an issue, or open a PR
and we will treat the diff as the proposal.

Issues: https://github.com/chatlychat/chatly-swift/issues · Docs: https://chatlychat.com/docs
