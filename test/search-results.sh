#!/usr/bin/env bash
set -euo pipefail
# Run from the fork root after the app's scripts/build-libghostty.sh finishes.
# Pass the build-owned support directory (never a writable shared cache).
support="${1:?usage: test/search-results.sh <ghostty-support-directory>}"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
swiftc -parse-as-library -I macos/GhosttyKit.xcframework/macos-arm64/Headers \
  test/search-results.swift macos/GhosttyKit.xcframework/macos-arm64/libghostty-fat.a \
  "$support"/aligned/*.a "$support"/lib/libcompiler_rt.a -lc++ \
  -framework AppKit -framework Carbon -framework CoreText -framework Metal \
  -framework QuartzCore -framework IOKit -framework Foundation -o "$test_dir/fixture"
"$test_dir/fixture"
