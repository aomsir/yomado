#!/bin/bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  printf 'Usage: %s <dedicated-release-archives-directory> <https-download-url-prefix/>\n' "$0" >&2
  exit 2
fi
ym_root="$(cd "$(dirname "$0")/.." && pwd -P)"
ym_sparkle="$("$ym_root/scripts/fetch-sparkle.sh")"
ym_archives="$(cd "$1" && pwd -P)"
ym_prefix="$2"
ym_account="${YOMADO_SPARKLE_KEY_ACCOUNT:-yomado-updates}"

# -p only reads an existing public key. This script never creates, exports,
# imports, or prints a private key, and never publishes the resulting feed.
ym_public_key="$("$ym_sparkle/bin/generate_keys" --account "$ym_account" -p)"
python3 - "$ym_archives" "$ym_prefix" "$ym_public_key" <<'PY'
import base64
from pathlib import Path, PurePosixPath
import plistlib
import re
import sys
from urllib.parse import urlsplit
import zipfile

directory, prefix, public_key = Path(sys.argv[1]), sys.argv[2], sys.argv[3].strip()
def fail(message):
    raise SystemExit(message)
try:
    decoded = base64.b64decode(public_key, validate=True)
except ValueError:
    fail("The selected Keychain account has no valid public EdDSA key.")
if len(decoded) != 32 or not any(decoded):
    fail("The selected Keychain account has no valid public EdDSA key.")
url = urlsplit(prefix)
if (url.scheme != "https" or not url.hostname or url.username or url.password
        or url.query or url.fragment or not url.path.endswith("/")):
    fail("Use an HTTPS download prefix ending in / without credentials, query, or fragment.")
archives = sorted(directory.glob("*.zip"))
if len(archives) != 1:
    fail("Use a dedicated release directory containing exactly one final ZIP archive.")
versions = set()
for archive in archives:
    with zipfile.ZipFile(archive) as package:
        names = package.namelist()
        if any(PurePosixPath(n).is_absolute() or ".." in PurePosixPath(n).parts for n in names):
            fail("An archive contains unsafe file paths.")
        if any(not n.startswith("Yomado.app/") for n in names):
            fail("Each update ZIP must contain only Yomado.app.")
        try:
            info = plistlib.loads(package.read("Yomado.app/Contents/Info.plist"))
        except (KeyError, plistlib.InvalidFileException):
            fail("An archive has no readable Yomado Info.plist.")
        if info.get("CFBundleIdentifier") != "dev.chekusu.yomado":
            fail("An archive has the wrong bundle identifier.")
        if info.get("SUPublicEDKey") != public_key:
            fail("An archive public key does not match the selected Keychain account.")
        if info.get("SUFeedURL") != "https://raw.githubusercontent.com/chekusu/yomado/main/appcast.xml":
            fail("An archive does not use the production yomado appcast URL.")
        if info.get("SURequireSignedFeed") is not True or info.get("SUVerifyUpdateBeforeExtraction") is not True:
            fail("An archive must require signed feeds and verification before extraction.")
        version = info.get("CFBundleVersion", "")
        if not isinstance(version, str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", version) or version in versions:
            fail("Archive build versions must be distinct numeric CFBundleVersion values.")
        versions.add(version)
print("Archive configuration and signing-key match verified.")
PY

# Do not create deltas until real full-update installation has been accepted.
# Re-running this command also re-signs an existing feed or changed notes.
"$ym_sparkle/bin/generate_appcast" --account "$ym_account" \
  --maximum-versions 1 --maximum-deltas 0 --download-url-prefix "$ym_prefix" \
  --link https://yomado.app/ -o "$ym_archives/appcast.xml" "$ym_archives"
"$ym_sparkle/bin/sign_update" --account "$ym_account" --verify "$ym_archives/appcast.xml"

python3 - "$ym_archives" "$ym_prefix" "$ym_sparkle/bin/sign_update" "$ym_account" <<'PY'
import base64
from pathlib import Path
import subprocess
import sys
from urllib.parse import unquote, urlsplit
import xml.etree.ElementTree as ET

directory, prefix, verifier, account = Path(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
feed = directory / "appcast.xml"
raw = feed.read_text()
if any(value in raw for value in ("/Users/", "/private/", "/home/", "file://", "localhost", "127.0.0.1")):
    raise SystemExit("The generated feed contains local/private location text; review before publishing.")
ns = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
items = ET.fromstring(raw).findall("channel/item")
if not items:
    raise SystemExit("The generated appcast has no update items.")
for item in items:
    enclosure = item.find("enclosure")
    if enclosure is None:
        raise SystemExit("An appcast item has no update enclosure.")
    url = enclosure.get("url", "")
    name = unquote(urlsplit(url).path.rsplit("/", 1)[-1])
    if not url.startswith(prefix) or Path(name).name != name:
        raise SystemExit("An appcast item is outside the intended download prefix.")
    archive = directory / name
    signature = enclosure.get(ns + "edSignature", "")
    try:
        signature_size = len(base64.b64decode(signature, validate=True))
    except ValueError:
        signature_size = 0
    if not archive.is_file() or str(archive.stat().st_size) != enclosure.get("length") or signature_size != 64:
        raise SystemExit("An appcast item has invalid archive size or EdDSA signature metadata.")
    subprocess.run([verifier, "--account", account, "--verify", str(archive), signature], check=True)
print(f"Verified signed appcast and {len(items)} update archive signature(s). No files were published.")
PY
