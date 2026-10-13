#if os(macOS)
import Foundation
import XCTest

/// Compiles the package for **iOS**, as part of `swift test`.
///
/// ── The bug this test is ───────────────────────────────────────────────────
///
/// `ChatlyViewController`, `ChatlyMessagesView`, `ChatlyComposerView`,
/// `ChatlyMessageCell` and `ChatlyTheme` are all inside
/// `#if canImport(UIKit)`, and `canImport(UIKit)` is **false** when
/// `swift build` runs on macOS. A third of the library was therefore excluded
/// from every build this project has ever run — `swift build`, `swift test`,
/// and the mirror's CI, which runs exactly those two commands on `macos-14`.
///
/// It had 9 errors across 7 members the client did not have. Nothing was
/// hiding them; nothing was looking.
///
/// So the deliverable is not that it compiles. It is that **the iOS compile
/// happens on every run**, and `swift test` is the only thing that runs. A
/// unit test is a strange place for a cross-compile, and it is the right one:
/// there is no way to make SwiftPM cross-compile a package as part of its own
/// build, and a CI step would be invisible to anybody working locally — which
/// is where this was broken for the whole life of the package.
///
/// ── Why there is no environment variable to switch it off ──────────────────
///
/// Because that is how it comes back. It skips in exactly one circumstance —
/// no iOS SDK on the machine, which is a fact rather than a preference — and
/// the mirror's `macos-14` runner always has one. See
/// `reference_integration_tier_soft_skips`: a tier that reports a pass for
/// tests that never ran is worse than a tier that is honestly missing.
final class IOSBuildTests: XCTestCase {

    func testThePackageCompilesForIOS() throws {
        let script = Self.packageRoot.appendingPathComponent("Scripts/ios-build.sh")
        XCTAssertTrue(FileManager.default.fileExists(atPath: script.path),
                      "Scripts/ios-build.sh is the command; it must ship with the package")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        process.currentDirectoryURL = Self.packageRoot
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        // Read before waiting: a full xcodebuild log will fill the pipe
        // buffer, and a process blocked on a write it cannot complete never
        // exits — which would hang `swift test` rather than fail it.
        let log = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()

        if process.terminationStatus == 2 {
            throw XCTSkip("no iOS SDK on this machine:\n\(log)")
        }
        XCTAssertEqual(process.terminationStatus, 0,
                       "the UIKit half of this package does not compile for iOS:\n\(log)")
        // A warning is not a pass being generous. The UIKit sources were
        // warning-free when this was written and keeping them that way is
        // what stops the log becoming noise nobody reads.
        XCTAssertFalse(log.contains("warning:"), "new warnings in the iOS build:\n\(log)")
    }

    /// `#filePath` is `…/Tests/ChatlyTests/IOSBuildTests.swift`. Derived from
    /// the source location rather than the working directory, because
    /// `swift test` and Xcode disagree about what the latter is.
    private static var packageRoot: URL {
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ChatlyTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // the package
    }
}
#endif
