#!/bin/bash
set -euo pipefail

# Image-only app icon regressions; never launch yomado or create UI.
ym_icon_test_root="$(cd "$(dirname "$0")/.." && pwd -P)"
ym_icon_test_stage="$(mktemp -d "${TMPDIR:-/tmp}/Yomado-app-icon-tests.XXXXXX")"
trap 'rm -rf "$ym_icon_test_stage"' EXIT
ym_icon_test_developer="${YOMADO_DEVELOPER_DIR:-$(xcode-select -p)}"
ym_icon_test_clang="$(DEVELOPER_DIR="$ym_icon_test_developer" /usr/bin/xcrun --find clang)"
ym_icon_test_sdk="$(DEVELOPER_DIR="$ym_icon_test_developer" /usr/bin/xcrun --sdk macosx --show-sdk-path)"

"$ym_icon_test_clang" -fobjc-arc -Wall -Wextra -Werror -isysroot "$ym_icon_test_sdk" \
  -mmacosx-version-min=14.0 \
  -ffile-prefix-map="$ym_icon_test_root"=. -fmacro-prefix-map="$ym_icon_test_root"=. \
  "$ym_icon_test_root/tests/AppIconTests.m" \
  -framework AppKit -o "$ym_icon_test_stage/AppIconTests"

"$ym_icon_test_clang" -fobjc-arc -Wall -Wextra -Werror -isysroot "$ym_icon_test_sdk" \
  -mmacosx-version-min=14.0 \
  -ffile-prefix-map="$ym_icon_test_root"=. -fmacro-prefix-map="$ym_icon_test_root"=. \
  "$ym_icon_test_root/scripts/RenderAppIcon.m" \
  -framework Foundation -framework CoreGraphics -framework ImageIO \
  -o "$ym_icon_test_stage/RenderAppIcon"

if "$ym_icon_test_stage/RenderAppIcon"; then
  printf 'FAIL RenderAppIcon must reject missing arguments\n' >&2
  exit 1
fi
for invalid_size in 0 17 2048 32px abc; do
  if "$ym_icon_test_stage/RenderAppIcon" \
    "$ym_icon_test_root/app/Resources/night-window.png" \
    "$ym_icon_test_stage/invalid-size.png" "$invalid_size"; then
    printf 'FAIL RenderAppIcon must reject size %s\n' "$invalid_size" >&2
    exit 1
  fi
done
if "$ym_icon_test_stage/RenderAppIcon" \
  "$ym_icon_test_root/app/Resources/night-window.png" \
  "$ym_icon_test_stage/nonexistent-parent/output.png" 1024; then
  printf 'FAIL RenderAppIcon must reject missing output parent\n' >&2
  exit 1
fi

/usr/bin/iconutil -c iconset "$ym_icon_test_root/app/Resources/Yomado.icns" \
  -o "$ym_icon_test_stage/current.iconset"
"$ym_icon_test_stage/AppIconTests" "$ym_icon_test_stage/current.iconset" \
  "$ym_icon_test_root/app/Resources/night-window.png"

ym_icon_fixture="$ym_icon_test_stage/project with spaces"
mkdir -p "$ym_icon_fixture/scripts" "$ym_icon_fixture/app/Resources"
cp "$ym_icon_test_root/scripts/build-icon.sh" "$ym_icon_fixture/scripts/"
cp "$ym_icon_test_root/scripts/RenderAppIcon.m" "$ym_icon_fixture/scripts/"
cp "$ym_icon_test_root/app/Resources/night-window.png" "$ym_icon_fixture/app/Resources/"
cp "$ym_icon_test_root/app/Resources/Yomado.icns" "$ym_icon_fixture/app/Resources/"
(cd "$ym_icon_test_stage" && bash "$ym_icon_fixture/scripts/build-icon.sh")
/usr/bin/iconutil -c iconset "$ym_icon_fixture/app/Resources/Yomado.icns" \
  -o "$ym_icon_test_stage/first.iconset"
cp "$ym_icon_fixture/app/Resources/Yomado.icns" "$ym_icon_test_stage/last-good.icns"

(cd "$ym_icon_test_stage" && bash "$ym_icon_fixture/scripts/build-icon.sh")
/usr/bin/iconutil -c iconset "$ym_icon_fixture/app/Resources/Yomado.icns" \
  -o "$ym_icon_test_stage/second.iconset"

"$ym_icon_test_stage/AppIconTests" "$ym_icon_test_stage/first.iconset" \
  "$ym_icon_test_root/app/Resources/night-window.png" \
  "$ym_icon_test_stage/second.iconset"
"$ym_icon_test_stage/AppIconTests" "$ym_icon_test_stage/current.iconset" \
  "$ym_icon_test_root/app/Resources/night-window.png" \
  "$ym_icon_test_stage/first.iconset"
cmp "$ym_icon_test_root/app/Resources/night-window.png" \
  "$ym_icon_fixture/app/Resources/night-window.png"

reset_fixture() {
  rm -rf "$ym_icon_fixture"
  mkdir -p "$ym_icon_fixture/scripts" "$ym_icon_fixture/app/Resources"
  cp "$ym_icon_test_root/scripts/build-icon.sh" "$ym_icon_fixture/scripts/"
  cp "$ym_icon_test_root/scripts/RenderAppIcon.m" "$ym_icon_fixture/scripts/"
  cp "$ym_icon_test_root/app/Resources/night-window.png" "$ym_icon_fixture/app/Resources/"
  cp "$ym_icon_test_stage/last-good.icns" "$ym_icon_fixture/app/Resources/Yomado.icns"
}

# Missing source
reset_fixture
rm -f "$ym_icon_fixture/app/Resources/night-window.png"
if bash "$ym_icon_fixture/scripts/build-icon.sh" >"$ym_icon_test_stage/failure.log" 2>&1; then
  printf 'FAIL invalid source must be rejected\n' >&2
  exit 1
fi
cmp "$ym_icon_test_stage/last-good.icns" "$ym_icon_fixture/app/Resources/Yomado.icns"
test -s "$ym_icon_test_stage/failure.log"

# Text substituted for PNG
reset_fixture
printf 'not an image\n' > "$ym_icon_fixture/app/Resources/night-window.png"
if bash "$ym_icon_fixture/scripts/build-icon.sh" >"$ym_icon_test_stage/failure.log" 2>&1; then
  printf 'FAIL invalid source must be rejected\n' >&2
  exit 1
fi
cmp "$ym_icon_test_stage/last-good.icns" "$ym_icon_fixture/app/Resources/Yomado.icns"
test -s "$ym_icon_test_stage/failure.log"

# Non-square source
reset_fixture
/usr/bin/sips -z 100 200 "$ym_icon_test_root/app/Resources/night-window.png" \
  --out "$ym_icon_fixture/app/Resources/night-window.png" >/dev/null
if bash "$ym_icon_fixture/scripts/build-icon.sh" >"$ym_icon_test_stage/failure.log" 2>&1; then
  printf 'FAIL invalid source must be rejected\n' >&2
  exit 1
fi
cmp "$ym_icon_test_stage/last-good.icns" "$ym_icon_fixture/app/Resources/Yomado.icns"
test -s "$ym_icon_test_stage/failure.log"

# JPEG bytes with a .png name
reset_fixture
/usr/bin/sips -s format jpeg "$ym_icon_test_root/app/Resources/night-window.png" \
  --out "$ym_icon_test_stage/fake-source.jpg" >/dev/null
/bin/cp "$ym_icon_test_stage/fake-source.jpg" "$ym_icon_fixture/app/Resources/night-window.png"
if bash "$ym_icon_fixture/scripts/build-icon.sh" >"$ym_icon_test_stage/failure.log" 2>&1; then
  printf 'FAIL invalid source must be rejected\n' >&2
  exit 1
fi
cmp "$ym_icon_test_stage/last-good.icns" "$ym_icon_fixture/app/Resources/Yomado.icns"
test -s "$ym_icon_test_stage/failure.log"

printf 'PASS app icon packing regressions\n'
