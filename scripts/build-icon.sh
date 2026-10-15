#!/bin/bash
set -euo pipefail

# Repackage the approved Image Generation source into standard macOS sizes
# with transparent app-icon padding on each canvas.
ym_icon_root="$(cd "$(dirname "$0")/.." && pwd -P)"
ym_icon_source="$ym_icon_root/app/Resources/night-window.png"
ym_icon_stage="$(mktemp -d "${TMPDIR:-/tmp}/Yomado-icon.XXXXXX")"
ym_icon_pending=""
cleanup() {
  if [ -n "${ym_icon_stage:-}" ]; then
    rm -rf "$ym_icon_stage"
  fi
  if [ -n "${ym_icon_pending:-}" ] && [ -e "$ym_icon_pending" ]; then
    rm -f "$ym_icon_pending"
  fi
}
trap cleanup EXIT

ym_icon_set="$ym_icon_stage/Yomado.iconset"
mkdir -p "$ym_icon_set"

ym_icon_developer="${YOMADO_DEVELOPER_DIR:-$(xcode-select -p)}"
ym_icon_clang="$(DEVELOPER_DIR="$ym_icon_developer" /usr/bin/xcrun --find clang)"
ym_icon_sdk="$(DEVELOPER_DIR="$ym_icon_developer" /usr/bin/xcrun --sdk macosx --show-sdk-path)"

"$ym_icon_clang" -fobjc-arc -Wall -Wextra -Werror -isysroot "$ym_icon_sdk" \
  -mmacosx-version-min=14.0 \
  -ffile-prefix-map="$ym_icon_root"=. -fmacro-prefix-map="$ym_icon_root"=. \
  "$ym_icon_root/scripts/RenderAppIcon.m" \
  -framework Foundation -framework CoreGraphics -framework ImageIO \
  -o "$ym_icon_stage/RenderAppIcon"

while read -r ym_icon_name ym_icon_size; do
  "$ym_icon_stage/RenderAppIcon" "$ym_icon_source" \
    "$ym_icon_set/$ym_icon_name.png" "$ym_icon_size"
done <<'SIZES'
icon_16x16 16
icon_16x16@2x 32
icon_32x32 32
icon_32x32@2x 64
icon_128x128 128
icon_128x128@2x 256
icon_256x256 256
icon_256x256@2x 512
icon_512x512 512
icon_512x512@2x 1024
SIZES

/usr/bin/iconutil -c icns "$ym_icon_set" -o "$ym_icon_stage/Yomado.icns"

ym_icon_target="$ym_icon_root/app/Resources/Yomado.icns"
if [ -d "$ym_icon_target" ]; then
  printf 'Refusing to replace directory: %s\n' "$ym_icon_target" >&2
  exit 1
fi

ym_icon_pending="$(mktemp "$ym_icon_root/app/Resources/.Yomado.icns.XXXXXX")"
/bin/cp "$ym_icon_stage/Yomado.icns" "$ym_icon_pending"
/bin/chmod 644 "$ym_icon_pending"
/bin/mv -f "$ym_icon_pending" "$ym_icon_target"
ym_icon_pending=""
printf 'Packaged: app/Resources/Yomado.icns\n'
