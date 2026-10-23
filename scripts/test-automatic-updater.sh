#!/bin/bash
set -euo pipefail
ym_auto_root="$(cd "$(dirname "$0")/.." && pwd -P)"
ym_auto_framework="${YOMADO_SPARKLE_DIR:-$ym_auto_root/.build-deps/Sparkle-2.10.0}"
if [[ ! -d "$ym_auto_framework/Sparkle.framework" ]]; then
  echo "Missing pinned Sparkle 2.10.0 dependency; run the repository dependency setup first." >&2
  exit 1
fi
ym_auto_stage="$(mktemp -d "${TMPDIR:-/tmp}/Yomado-auto-tests.XXXXXX")"
trap 'rm -rf "$ym_auto_stage"' EXIT
ym_auto_developer="${YOMADO_DEVELOPER_DIR:-$(xcode-select -p)}"
ym_auto_clang="$(DEVELOPER_DIR="$ym_auto_developer" /usr/bin/xcrun --find clang)"
ym_auto_sdk="$(DEVELOPER_DIR="$ym_auto_developer" /usr/bin/xcrun --sdk macosx --show-sdk-path)"
"$ym_auto_clang" -fobjc-arc -Wall -Wextra -Werror -isysroot "$ym_auto_sdk" \
  -mmacosx-version-min=14.0 -ffile-prefix-map="$ym_auto_root"=. -fmacro-prefix-map="$ym_auto_root"=. \
  -F "$ym_auto_framework" -I "$ym_auto_root/app" \
  "$ym_auto_root/app/AutomaticUpdater.m" "$ym_auto_root/tests/AutomaticUpdaterTests.m" \
  -framework Foundation -framework AppKit -framework Sparkle \
  -Wl,-rpath,"$ym_auto_framework" -o "$ym_auto_stage/AutomaticUpdaterTests"
"$ym_auto_stage/AutomaticUpdaterTests"
