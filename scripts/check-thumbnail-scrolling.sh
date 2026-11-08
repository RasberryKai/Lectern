#!/bin/sh
# Opens an isolated test window and verifies animation in both directions and list boundaries.
set -eu
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CHECK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/lectern-scroll-check.XXXXXX")
trap 'rm -rf "$CHECK_DIR"' EXIT

swiftc -swift-version 6 -parse-as-library \
  "$ROOT_DIR/Sources/LecternApp/Lecture/CenteredThumbnailList.swift" \
  "$ROOT_DIR/scripts/ThumbnailScrollingCheck.swift" \
  -o "$CHECK_DIR/ThumbnailScrollingCheck"
"$CHECK_DIR/ThumbnailScrollingCheck"
