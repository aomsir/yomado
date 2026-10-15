#!/bin/bash
set -euo pipefail

ym_panel_root="$(cd "$(dirname "$0")/.." && pwd -P)"
ym_panel_stage="$(mktemp -d "${TMPDIR:-/tmp}/Yomado-panel-tests.XXXXXX")"
trap 'rm -rf "$ym_panel_stage"' EXIT
ym_panel_developer="${YOMADO_DEVELOPER_DIR:-$(xcode-select -p)}"
ym_panel_clang="$(DEVELOPER_DIR="$ym_panel_developer" /usr/bin/xcrun --find clang)"
ym_panel_sdk="$(DEVELOPER_DIR="$ym_panel_developer" /usr/bin/xcrun --sdk macosx --show-sdk-path)"

# Compiles the production presenter. Tests cover geometry + injected lifecycle;
# no NSApplication/NSWindow or real display operations.
"$ym_panel_clang" -fobjc-arc -Wall -Wextra -Werror -isysroot "$ym_panel_sdk" \
  -mmacosx-version-min=14.0 \
  -ffile-prefix-map="$ym_panel_root"=. -fmacro-prefix-map="$ym_panel_root"=. \
  -I "$ym_panel_root/app" -I "$ym_panel_root/bridge" \
  "$ym_panel_root/tests/PanelPresentationTests.m" \
  "$ym_panel_root/app/PanelPresentation.m" "$ym_panel_root/bridge/VDVirtualDisplay.m" \
  -framework AppKit -framework CoreGraphics -framework ApplicationServices -o "$ym_panel_stage/PanelPresentationTests"
"$ym_panel_stage/PanelPresentationTests"
