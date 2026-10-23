#!/bin/bash
set -euo pipefail

ym_root="$(cd "$(dirname "$0")/.." && pwd -P)"
ym_cache="${YOMADO_DEPS_DIR:-$ym_root/.build-deps}"
ym_version=2.10.0
ym_sha256=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
ym_archive="$ym_cache/Sparkle-$ym_version.tar.xz"
ym_destination="$ym_cache/Sparkle-$ym_version"
ym_url="https://github.com/sparkle-project/Sparkle/releases/download/$ym_version/Sparkle-$ym_version.tar.xz"
mkdir -p "$ym_cache"
ym_lock="$ym_cache/.sparkle-fetch.lock"
ym_attempt=0
until mkdir "$ym_lock" 2>/dev/null; do
  ym_attempt=$((ym_attempt + 1))
  if [ "$ym_attempt" -ge 300 ]; then
    printf 'Sparkle dependency cache is busy. Retry after the other build finishes.\n' >&2
    exit 1
  fi
  sleep 0.1
done
ym_download=""
trap 'if [ -n "$ym_download" ]; then rm -f "$ym_download"; fi; rmdir "$ym_lock"' EXIT
if [ ! -f "$ym_archive" ]; then
  ym_download="$(mktemp "$ym_cache/.sparkle-download.XXXXXX")"
  curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
    --tlsv1.2 --connect-timeout 20 --max-time 180 --retry 2 "$ym_url" -o "$ym_download"
  ym_actual="$(shasum -a 256 "$ym_download" | awk '{print $1}')"
  [ "$ym_actual" = "$ym_sha256" ] || { printf 'Sparkle archive checksum mismatch.\n' >&2; exit 1; }
  mv "$ym_download" "$ym_archive"
  ym_download=""
fi
ym_actual="$(shasum -a 256 "$ym_archive" | awk '{print $1}')"
[ "$ym_actual" = "$ym_sha256" ] || { printf 'Cached Sparkle archive checksum mismatch; remove it and retry.\n' >&2; exit 1; }

# Validate the reusable expanded cache against the pinned archive, rather than
# trusting a marker file. Do not run a cached signing tool that was modified.
python3 - "$ym_archive" "$ym_destination" <<'PY'
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile

archive, destination = Path(sys.argv[1]), Path(sys.argv[2])
roots = ("Sparkle.framework", "bin", "LICENSE")
with tarfile.open(archive, "r:xz") as package:
    members = []
    for member in package:
        member.name = member.name[2:] if member.name.startswith("./") else member.name
        if any(member.name == r or member.name.startswith(r + "/") for r in roots):
            members.append(member)
    if not members:
        raise SystemExit("Sparkle distribution has no expected files.")
    if not destination.exists():
        staging = Path(tempfile.mkdtemp(prefix=".sparkle-extract-", dir=destination.parent))
        try:
            subprocess.run(["/usr/bin/tar", "-xJf", str(archive), "-C", str(staging), *["./" + r for r in roots]], check=True)
            staging.rename(destination)
        finally:
            if staging.exists():
                shutil.rmtree(staging)
    def digest(stream):
        result = hashlib.sha256()
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(chunk)
        return result.digest()
    for member in members:
        target = destination / member.name
        valid = False
        if member.issym():
            valid = target.is_symlink() and os.readlink(target) == member.linkname
        elif member.isdir():
            valid = target.is_dir() and not target.is_symlink()
        elif member.isfile() and target.is_file() and not target.is_symlink():
            with package.extractfile(member) as expected, target.open("rb") as actual:
                valid = digest(expected) == digest(actual)
            valid = valid and (target.stat().st_mode & 0o111) == (member.mode & 0o111)
        if not valid:
            raise SystemExit("Expanded Sparkle cache differs from the pinned archive; remove that cache and retry.")
    expected_paths = {m.name.rstrip("/") for m in members}
    for member in members:
        expected_paths.update(str(parent) for parent in Path(member.name).parents if str(parent) != ".")
    for root in roots:
        paths = [destination / root]
        if (destination / root).is_dir():
            for current, dirs, files in os.walk(destination / root, followlinks=False):
                paths.extend(Path(current) / name for name in dirs + files)
        if any(str(path.relative_to(destination)) not in expected_paths for path in paths):
            raise SystemExit("Expanded Sparkle cache contains unexpected files; remove that cache and retry.")
print(destination.resolve())
PY
