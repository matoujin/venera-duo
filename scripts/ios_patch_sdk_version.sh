#!/usr/bin/env bash
# Patch a built Runner.app so LiveContainer / iPhone Duo treat it as an
# iOS 27.1 SDK build (full-bleed on fold/unfold, no letterboxing).
#
# Usage:
#   bash scripts/ios_patch_sdk_version.sh Payload/Runner.app
#
# Must run after `flutter build ios --release --no-codesign` and before
# zipping the Payload into an .ipa. Requires Python 3; codesign/plutil are
# used when available (macOS CI).

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <path-to-Runner.app>" >&2
  exit 1
fi

APP_PATH="$1"
if [[ ! -d "$APP_PATH" ]]; then
  echo "Error: Runner.app not found at: $APP_PATH" >&2
  exit 1
fi

APP_PATH="$(cd "$APP_PATH" && pwd)"
INFO_PLIST="$APP_PATH/Info.plist"
MAIN_BINARY="$APP_PATH/Runner"

if [[ ! -f "$INFO_PLIST" ]]; then
  echo "Error: Info.plist missing in $APP_PATH" >&2
  exit 1
fi

echo "==> Patching Info.plist for iOS 27.1 / Duo full-screen"

python3 - "$INFO_PLIST" <<'PY'
import plistlib
import sys

path = sys.argv[1]
with open(path, "rb") as f:
    data = plistlib.load(f)

# Official iPhoneOS27.1.sdk SDKSettings / Xcode 27.1 build identifiers
data["DTPlatformName"] = "iphoneos"
data["DTPlatformVersion"] = "27.1"
data["DTPlatformBuild"] = "24A94232"
data["DTSDKName"] = "iphoneos27.1"
data["DTSDKBuild"] = "24A94232"
data["DTXcode"] = "2710"
data["DTXcodeBuild"] = "27A9275"
data["UIDeviceFamily"] = [1, 2]
data["MinimumOSVersion"] = "16.1"
# Distinct bundle id so SpringBoard / LiveContainer do not reuse old
# compatibility-mode state cached under com.github.wgh136.venera.
data["CFBundleIdentifier"] = "com.github.wgh136.venera.duo"

# Remove full-screen compatibility key entirely (do not leave false).
data.pop("UIRequiresFullScreen", None)

# Legacy launch storyboards / images pin a fixed phone size (e.g. 375×667)
# and force Duo into the letterboxed compatibility window. Strip them and
# keep only the modern UILaunchScreen dictionary.
for key in (
    "UILaunchStoryboardName",
    "UILaunchImageFile",
    "UILaunchImages",
):
    data.pop(key, None)
data["UILaunchScreen"] = {}

_orientations = [
    "UIInterfaceOrientationPortrait",
    "UIInterfaceOrientationPortraitUpsideDown",
    "UIInterfaceOrientationLandscapeLeft",
    "UIInterfaceOrientationLandscapeRight",
]
data["UISupportedInterfaceOrientations"] = list(_orientations)
data["UISupportedInterfaceOrientations~iphone"] = list(_orientations)
data["UISupportedInterfaceOrientations~ipad"] = list(_orientations)

manifest = data.get("UIApplicationSceneManifest")
if isinstance(manifest, dict):
    manifest["UIApplicationSupportsMultipleScenes"] = True
    data["UIApplicationSceneManifest"] = manifest

with open(path, "wb") as f:
    plistlib.dump(data, f, sort_keys=False)
print(f"Patched {path}")
PY

echo "==> Removing compiled LaunchScreen.storyboardc (legacy fixed size)"
rm -rf "$APP_PATH/Base.lproj/LaunchScreen.storyboardc"
# Also drop any loose LaunchScreen leftovers under the app bundle.
find "$APP_PATH" -name 'LaunchScreen.storyboardc' -type d -prune -exec rm -rf {} + 2>/dev/null || true

echo "==> Patching LC_BUILD_VERSION minos=16.1.0 / sdk=27.1.0 in Mach-O binaries"

python3 - "$APP_PATH" <<'PY'
"""Patch LC_BUILD_VERSION.sdk in thin and FAT Mach-O binaries to 27.1.0.

Supports:
  - Thin 64-bit LE (magic bytes CF FA ED FE → 0xFEEDFACF when read LE)
  - Thin 64-bit BE / swapped (0xCFFAEDFE when read LE)
  - FAT universal (0xCAFEBABE / 0xBEBAFECA) — walk every arch slice
    including Flutter's App.framework/App.
"""

from __future__ import annotations

import struct
import sys
from pathlib import Path

APP = Path(sys.argv[1])
TARGET_MINOS = 0x00100100  # 16.1.0
TARGET_SDK = 0x001B0100  # 27.1.0
LC_BUILD_VERSION = 0x32
MH_MAGIC_32 = 0xFEEDFACE
MH_CIGAM_32 = 0xCEFAEDFE
MH_MAGIC_64 = 0xFEEDFACF
MH_CIGAM_64 = 0xCFFAEDFE
FAT_MAGIC = 0xCAFEBABE
FAT_CIGAM = 0xBEBAFECA


def _magic_le(data: bytes | bytearray, off: int = 0) -> int:
    return struct.unpack_from("<I", data, off)[0]


def is_macho(data: bytes) -> bool:
    if len(data) < 4:
        return False
    return _magic_le(data) in (
        MH_MAGIC_32,
        MH_MAGIC_64,
        MH_CIGAM_32,
        MH_CIGAM_64,
        FAT_MAGIC,
        FAT_CIGAM,
    )


def patch_thin(buf: bytearray, base: int = 0) -> int:
    """Patch one thin Mach-O slice. Returns count of LC_BUILD_VERSION cmds changed."""
    if base + 32 > len(buf):
        return 0
    magic = _magic_le(buf, base)
    # Read magic as little-endian: MH_MAGIC_* ⇒ file is LE; MH_CIGAM_* ⇒ file is BE.
    if magic in (MH_MAGIC_32, MH_MAGIC_64):
        endian = "<"
        header_size = 28 if magic == MH_MAGIC_32 else 32
    elif magic in (MH_CIGAM_32, MH_CIGAM_64):
        endian = ">"
        header_size = 28 if magic == MH_CIGAM_32 else 32
    else:
        return 0

    # mach_header[_64]: magic,cputype,cpusubtype,filetype,ncmds,sizeofcmds,flags[,reserved]
    ncmds = struct.unpack_from(endian + "I", buf, base + 16)[0]
    offset = base + header_size
    patched = 0
    for _ in range(ncmds):
        if offset + 8 > len(buf):
            break
        cmd, cmdsize = struct.unpack_from(endian + "II", buf, offset)
        if cmdsize < 8:
            break
        if cmd == LC_BUILD_VERSION and cmdsize >= 24:
            # cmd, cmdsize, platform, minos, sdk, ntools
            minos_off = offset + 12
            sdk_off = offset + 16
            old_minos = struct.unpack_from(endian + "I", buf, minos_off)[0]
            old_sdk = struct.unpack_from(endian + "I", buf, sdk_off)[0]
            struct.pack_into(endian + "I", buf, minos_off, TARGET_MINOS)
            struct.pack_into(endian + "I", buf, sdk_off, TARGET_SDK)
            if old_minos != TARGET_MINOS or old_sdk != TARGET_SDK:
                patched += 1
        offset += cmdsize
    return patched


def patch_file(path: Path) -> int:
    data = bytearray(path.read_bytes())
    if not is_macho(data):
        return 0
    magic = _magic_le(data)
    total = 0
    if magic in (FAT_MAGIC, FAT_CIGAM):
        # FAT headers are always big-endian on disk (0xCAFEBABE).
        nfat = struct.unpack_from(">I", data, 4)[0]
        for i in range(nfat):
            # fat_arch: cputype, cpusubtype, offset, size, align (all BE)
            arch_offset = struct.unpack_from(">I", data, 8 + i * 20 + 8)[0]
            total += patch_thin(data, arch_offset)
    else:
        total += patch_thin(data, 0)
    if total:
        path.write_bytes(data)
    return total


def collect_binaries(app: Path) -> list[Path]:
    found: list[Path] = []
    main_bin = app / "Runner"
    if main_bin.is_file() and not main_bin.is_symlink():
        found.append(main_bin)
    for sub in ("Frameworks", "PlugIns"):
        root = app / sub
        if not root.is_dir():
            continue
        for p in root.rglob("*"):
            if not p.is_file() or p.is_symlink():
                continue
            # Prefer typical framework binary names + any Mach-O by magic
            # (covers App.framework/App FAT universal binaries).
            try:
                head = p.read_bytes()[:4]
            except OSError:
                continue
            if is_macho(head):
                found.append(p)
    # Deduplicate by resolved path
    seen: set[Path] = set()
    unique: list[Path] = []
    for p in found:
        rp = p.resolve()
        if rp in seen:
            continue
        seen.add(rp)
        unique.append(p)
    return unique


patched_files = 0
patched_cmds = 0
for p in collect_binaries(APP):
    try:
        n = patch_file(p)
    except OSError as e:
        print(f"Skip {p}: {e}")
        continue
    if n:
        patched_files += 1
        patched_cmds += n
        print(f"  patched minos/sdk in {p.relative_to(APP)} ({n} LC_BUILD_VERSION)")

print(
    f"Done: {patched_cmds} LC_BUILD_VERSION minos/sdk field(s) "
    f"in {patched_files} file(s)"
)
PY

echo "==> Ad-hoc re-signing frameworks, plugins, and Runner.app"

resign() {
  local target="$1"
  if command -v codesign >/dev/null 2>&1; then
    codesign --force --sign - --preserve-metadata=identifier,entitlements "$target" 2>/dev/null \
      || codesign --force --sign - "$target"
  else
    echo "Warning: codesign not found; skipped resign of $target" >&2
  fi
}

if [[ -d "$APP_PATH/Frameworks" ]]; then
  while IFS= read -r -d '' fw; do
    resign "$fw"
  done < <(find "$APP_PATH/Frameworks" -maxdepth 1 \( -name '*.framework' -o -name '*.dylib' \) -print0 2>/dev/null)
fi

if [[ -d "$APP_PATH/PlugIns" ]]; then
  while IFS= read -r -d '' plugin; do
    resign "$plugin"
  done < <(find "$APP_PATH/PlugIns" -maxdepth 1 \( -name '*.appex' -o -name '*.framework' \) -print0 2>/dev/null)
fi

resign "$APP_PATH"

echo "==> iOS 27.1 Duo patch complete: $APP_PATH"
