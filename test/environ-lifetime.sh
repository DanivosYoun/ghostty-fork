#!/usr/bin/env bash
set -euo pipefail
# Run from the fork root after the app's scripts/build-libghostty.sh finishes.
# Pass the build-owned support directory (never a writable shared cache).
# Exits non-zero (139 before the fix) if Ghostty reads a stale libc environ.
support="${1:?usage: test/environ-lifetime.sh <ghostty-support-directory>}"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
swiftc -parse-as-library -I macos/GhosttyKit.xcframework/macos-arm64/Headers \
  test/environ-lifetime.swift macos/GhosttyKit.xcframework/macos-arm64/libghostty-internal.a \
  "$support"/aligned/*.a -lc++ \
  -framework AppKit -framework Carbon -framework CoreText -framework Metal \
  -framework QuartzCore -framework IOKit -framework Foundation -framework GameController \
  -framework MetalKit -o "$test_dir/fixture"
"$test_dir/fixture"
