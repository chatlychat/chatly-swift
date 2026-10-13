#!/usr/bin/env bash
#
# Compile this package FOR iOS.
#
# ── Why a whole script for one command ─────────────────────────────────────
#
# A third of this library is inside `#if canImport(UIKit)`, and `canImport`
# is FALSE when `swift build` runs on macOS. So `swift build` and `swift test`
# were both green while `ChatlyViewController` and its views had never been
# handed to a compiler at all: 9 errors across 7 members the client did not
# have, invisible to every gate this project runs.
#
# The fix that matters is not making it compile once. It is making the iOS
# compile HAPPEN on every run, which is what `IOSBuildTests` uses this for.
# It is a script rather than a line in a test so the command is also runnable
# by hand when the test tells you it failed.
#
# ── Why not `xcodebuild` ───────────────────────────────────────────────────
#
# This is equivalent, and 0.7s incremental against 11s:
#
#   xcodebuild -scheme Chatly -destination 'generic/platform=iOS' build
#
# It is not what runs here for one reason: `xcodebuild` generates
# `.swiftpm/xcode/package.xcworkspace` inside the package. That directory is
# gitignored in the monorepo but `scripts/sync-sdk-repos.mjs` copies from the
# FILESYSTEM, and `.swiftpm` is not in its `NEVER_COPY` set — so every mirror
# push would carry an Xcode workspace stub nobody asked for.
#
# ── Why BOTH -Xswiftc and -Xcc get the SDK ─────────────────────────────────
#
# `-Xswiftc -sdk` retargets the Swift frontend only. The clang importer keeps
# the macOS sysroot, so `canImport(UIKit)` flips to true and then the import
# fails with "cannot load underlying module for 'UIKit'" under a
# "using sysroot for 'MacOSX' but targeting 'iPhone'" warning. The `-Xcc`
# pair is what actually puts the iOS SDK in front of the importer.
#
# Exit codes: 0 built, 1 failed to build, 2 no iOS SDK on this machine.
set -euo pipefail

PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# iOS 14 is this package's floor, as declared in `Package.swift`. Compiling
# against a newer one would let an API the floor does not have through.
TARGET="${CHATLY_IOS_TARGET:-arm64-apple-ios14.0}"

if ! command -v xcrun >/dev/null 2>&1; then
  echo "ios-build: no xcrun on PATH — Xcode is required to compile the UIKit half." >&2
  exit 2
fi
if ! SDK="$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null)"; then
  echo "ios-build: no iphoneos SDK installed (xcrun --sdk iphoneos --show-sdk-path failed)." >&2
  exit 2
fi

# Its own scratch path, under the already-gitignored `.build`. Separate from
# the host build's because the two hold different triples and would otherwise
# invalidate each other on every alternating run; nested rather than in a temp
# directory so the 0.7s incremental survives, because a slow gate is a gate
# someone turns off.
SCRATCH="${CHATLY_IOS_SCRATCH:-$PACKAGE_DIR/.build/ios}"

set +e
LOG="$(cd "$PACKAGE_DIR" && swift build \
  --scratch-path "$SCRATCH" \
  -Xswiftc -sdk -Xswiftc "$SDK" \
  -Xswiftc -target -Xswiftc "$TARGET" \
  -Xcc -isysroot -Xcc "$SDK" \
  -Xcc -target -Xcc "$TARGET" 2>&1)"
STATUS=$?
set -e

# A warning must not read as a pass being generous, so print everything the
# compiler said either way.
if printf '%s\n' "$LOG" | grep -qE '(error|warning):'; then
  printf '%s\n' "$LOG" | grep -E '(error|warning):' | sed "s|$PACKAGE_DIR/||" | sort -u
fi

if [ "$STATUS" -ne 0 ]; then
  echo "ios-build: FAILED for $TARGET" >&2
  printf '%s\n' "$LOG" | tail -40 >&2
  exit 1
fi

echo "ios-build: ok ($TARGET, UIKit sources compiled)"
