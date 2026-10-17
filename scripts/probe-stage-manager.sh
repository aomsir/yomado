#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD_DIR="$(mktemp -d "/private/var/folders/91/wfrhw_p13kl1n4hz418s9t880000gn/T/opencode/yomado-stage-probe.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT
xcrun clang -fobjc-arc -Wall -Wextra -Werror -mmacosx-version-min=14.0 -I app \
  tests/StageManagerWindowProbe.m app/UpdateWorkspaceRecovery.m \
  -framework AppKit -framework CoreGraphics -framework ApplicationServices \
  -o "$BUILD_DIR/stage-manager-probe"
"$BUILD_DIR/stage-manager-probe" "$@"
