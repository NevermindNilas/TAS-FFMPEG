#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/build.sh
#
# One-shot build for the current platform:
#     fetch -> validate flags -> build deps -> build ffmpeg -> verify
#     -> manifest -> package
#
# Environment:
#   TARGET_ARCH   arm64 | x86_64 (defaults to the host arch). Meaningful on
#                 macOS (two native builds) and on Linux (x86_64 and aarch64,
#                 each built natively inside its own manylinux_2_28 image).
#                 It selects flags/ffmpeg.<os>.<arch>.flags as well as the
#                 artefact name, so it is not merely cosmetic: linux/arm64
#                 turns OFF QSV, VAAPI and AMF.
#   BUILD_ROOT    where intermediates go (default: ./build)
#   DIST_DIR      where archives go      (default: ./dist)
#
# On Windows this must run inside an MSYS2 MINGW64 shell, not cmd/PowerShell.
# On Linux it must run inside the manylinux_2_28 image for the matching arch
# -- see docker/Dockerfile.manylinux_2_28 and README.md#linux.
# ---------------------------------------------------------------------------
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$HERE/fetch-sources.sh"
"$HERE/validate-flags.sh"
"$HERE/build-deps.sh"
"$HERE/build-ffmpeg.sh"     # runs verify-output.sh + make-manifest.sh itself
"$HERE/package.sh"

echo
echo "Done. Archives in ${DIST_DIR:-$(cd "$HERE/.." && pwd)/dist}"
echo "Release also needs, ONCE per release (any platform):"
echo "    $HERE/corresponding-source.sh"
echo "    $HERE/emit-consumer-pin.sh"
