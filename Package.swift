// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "Chatly",
    platforms: [.iOS(.v14), .macOS(.v12)],
    products: [
        .library(name: "Chatly", targets: ["Chatly"]),
    ],
    targets: [
        .target(name: "Chatly", path: "Sources/Chatly"),
        .testTarget(name: "ChatlyTests", dependencies: ["Chatly"], path: "Tests/ChatlyTests"),
    ]
)
