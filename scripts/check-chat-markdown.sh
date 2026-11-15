#!/bin/sh
# Exercises the production Markdown renderer and WebKit citation bridge with fixture text.
set -eu
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CHECK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/lectern-markdown-check.XXXXXX")
trap 'rm -rf "$CHECK_DIR"' EXIT
swiftc -swift-version 6 -parse-as-library \
  "$ROOT_DIR/Sources/LecternApp/Lecture/ChatMarkdownView.swift" \
  "$ROOT_DIR/scripts/ChatMarkdownCheck.swift" \
  -o "$CHECK_DIR/ChatMarkdownCheck"
"$CHECK_DIR/ChatMarkdownCheck" "$@"
