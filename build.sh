#!/usr/bin/env bash
# Validated, hardware-only release. Keep the prior release until checks pass.
set -euo pipefail

if [[ ${1:-} == --help && $# == 1 ]]; then
    printf 'Usage: ./build.sh\nRequires Zig 0.16.0, PLAYDATE_SDK_PATH, Python 3, and arm-none-eabi-objdump.\nBUILD_JOBS defaults to 2. Output: zig-out/release/readr.pdx\n'
    exit 0
fi
if (( $# != 0 )); then
    printf 'Usage: ./build.sh [--help]\n' >&2
    exit 2
fi

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd -- "$project_dir"
for tool in zig python3 arm-none-eabi-objdump; do
    command -v "$tool" >/dev/null || { printf 'Required tool missing: %s\n' "$tool" >&2; exit 1; }
done
if [[ $(zig version) != 0.16.0 ]]; then
    printf 'This release build requires Zig 0.16.0.\n' >&2
    exit 1
fi
if [[ -z ${PLAYDATE_SDK_PATH:-} || ! -x "$PLAYDATE_SDK_PATH/bin/pdc" ]]; then
    printf 'Set PLAYDATE_SDK_PATH to an installed Playdate SDK directory.\n' >&2
    exit 1
fi
# Resolve relative SDK paths before passing them to build tools.
PLAYDATE_SDK_PATH=$(cd -- "$PLAYDATE_SDK_PATH" && pwd)
export PLAYDATE_SDK_PATH
jobs=${BUILD_JOBS:-2}
if [[ ! $jobs =~ ^[1-9][0-9]*$ ]]; then
    printf 'BUILD_JOBS must be a positive integer.\n' >&2
    exit 1
fi
sdk_version=$("$PLAYDATE_SDK_PATH/bin/pdc" --version)
python3 - "$sdk_version" <<'PY'
import re
import sys
v = re.fullmatch(r'(\d+)\.(\d+)\.(\d+)', sys.argv[1].strip())
if not v or tuple(map(int, v.groups())) < (3, 0, 0):
    sys.exit('Playdate SDK 3.0.0 or newer is required.')
PY

printf 'Checking Debug and ReleaseFast host tests (SDK %s)...\n' "$sdk_version"
# Keep both caches writable and project-local, including in restricted CI.
zig_args=(--global-cache-dir "$project_dir/.zig-cache/global" -j"$jobs")
zig build test -Dhardware-only=true "${zig_args[@]}" --summary failures
printf 'Debug host tests passed.\n'
zig build test -Dhardware-only=true -Doptimize=ReleaseFast "${zig_args[@]}" --summary failures
printf 'ReleaseFast host tests passed.\n'

mkdir -p zig-out
staging=$(mktemp -d "$project_dir/zig-out/.release-build.XXXXXX")
trap 'rm -rf -- "$staging"' EXIT
printf 'Building optimized hardware package...\n'
zig build -Dhardware-only=true -Dstrip-package=true -Doptimize=ReleaseFast \
    "${zig_args[@]}" --prefix "$staging" --summary all
python3 tools/check_device_stack.py "$staging/pdx_source_dir/pdex.elf"

# Keep the diagnostic ELF outside the PDX. Hash file contents so ZIP timestamps
# and compression settings do not affect package identification.
python3 - "$staging" "$project_dir/zig-out/release" "$sdk_version" <<'PY'
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys

stage, destination = map(Path, sys.argv[1:3])
package = stage / 'readr.pdx'
if not (package / 'pdex.bin').is_file() or not (package / 'pdex.bin').stat().st_size:
    sys.exit('Missing or empty hardware executable: pdex.bin')
for ext in ('so', 'dll', 'dylib', 'elf', 'pdb'):
    if (package / f'pdex.{ext}').exists():
        sys.exit(f'Unexpected non-device artifact: pdex.{ext}')
if not (package / 'pdxinfo').is_file() or not (package / 'assets/fonts').is_dir():
    sys.exit('Missing manifest or font resources')
release = stage / 'release'
release.mkdir()
shutil.move(str(package), release / package.name)
shutil.copy2(stage / 'pdx_source_dir/pdex.elf', release / 'pdex.elf')
hashes = []
for path in sorted((release / 'readr.pdx').rglob('*')):
    if path.is_file():
        hashes.append(f'{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.relative_to(release).as_posix()}\n')
(release / 'SHA256SUMS').write_text(''.join(hashes))
def git(*args):
    try:
        return subprocess.check_output(['git', *args], text=True, stderr=subprocess.DEVNULL).strip()
    except (OSError, subprocess.CalledProcessError):
        return None
(release / 'build-info.json').write_text(json.dumps({
    'zig': '0.16.0', 'sdk': sys.argv[3], 'optimize': 'ReleaseFast',
    'target': 'thumb-freestanding-eabihf', 'cpu': 'cortex_m7+vfp4d16sp',
    'hardware_only': True, 'package_debug_stripped': True,
    'commit': git('rev-parse', 'HEAD'), 'working_tree_status': git('status', '--porcelain'),
}, indent=2) + '\n')
previous = stage / 'previous-release'
if destination.exists():
    destination.rename(previous)
try:
    release.rename(destination)
except OSError:
    if previous.exists():
        previous.rename(destination)
    raise
print(f'Release ready: {destination / "readr.pdx"}')
print(f'PDX files: {len(hashes)}; hashes: {destination / "SHA256SUMS"}')
PY
