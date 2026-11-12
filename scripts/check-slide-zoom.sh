#!/bin/sh
# Exercises the production PDF viewer in an isolated window with generated PDFs.
set -eu
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CHECK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/lectern-zoom-check.XXXXXX")
trap 'rm -rf "$CHECK_DIR"' EXIT

swiftc -swift-version 6 -parse-as-library \
  "$ROOT_DIR/Sources/LecternApp/PDF/SlideImages.swift" \
  "$ROOT_DIR/Sources/LecternApp/PDF/ZoomableSlideView.swift" \
  "$ROOT_DIR/scripts/SlideZoomCheck.swift" \
  -o "$CHECK_DIR/SlideZoomCheck"
"$CHECK_DIR/SlideZoomCheck" "$@"
