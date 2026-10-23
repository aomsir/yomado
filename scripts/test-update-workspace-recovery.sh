#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/yomado-recovery-tests.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT
clang -fobjc-arc -Wall -Wextra -Werror -mmacosx-version-min=14.0 -Iapp \
  tests/UpdateWorkspaceRecoveryTests.m app/UpdateWorkspaceRecovery.m \
  -framework AppKit -framework ApplicationServices -framework CoreGraphics \
  -o "$BUILD_DIR/recovery-tests"
"$BUILD_DIR/recovery-tests"
