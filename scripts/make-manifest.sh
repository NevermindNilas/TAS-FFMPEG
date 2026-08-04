#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/make-manifest.sh <install-dir>
#
# Emits <install-dir>/manifest.json -- the machine-readable contract between
# this repo and its two consumers.
#
# WHY THIS EXISTS
#   There is no --build-suffix any more, so nelux's bundled libav* and TAS's
#   ffmpeg_shared/libav* have IDENTICAL file names. On Windows the first one
#   loaded into the process wins for both. That is SAFE if and only if they
#   are the same build. Nothing at the OS level enforces that, and the two
#   consumers ship on independent release cadences, so drift is a question of
#   when, not if.
#
#   manifest.json gives each consumer something cheap to assert at startup:
#
#       expected = json.load(open("manifest.json"))
#       assert nelux.ffmpeg_version_info() == expected["av_version_info"]
#       assert nelux.ffmpeg_soname_majors() == expected["soname_majors"]
#
#   av_version_info() is a one-call, always-present libavutil export that
#   returns the FFMPEG_VERSION string. Because scripts/build-ffmpeg.sh passes
#   --extra-version=tas, ours is "<version>-tas" -- verified against
#   ffbuild/version.sh:40 (`test -n "$3" && version=$version-$3`) and :48
#   (`#define FFMPEG_VERSION "$version"`). A stock distro or BtbN FFmpeg will
#   NEVER produce that string, so the assertion also catches "we accidentally
#   loaded someone else's FFmpeg", not just "we loaded an older ours".
#
#   Loading a drifted build must fail LOUDLY. See README.md#drift.
# ---------------------------------------------------------------------------
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_lock

INSTALL="${1:?usage: make-manifest.sh <install-dir>}"
OS="$(detect_os)"
ARCH="${TARGET_ARCH:-$(detect_arch)}"
EXTRA_VERSION="tas"           # must match --extra-version in build-ffmpeg.sh
AV_VERSION_INFO="$FFMPEG_VERSION-$EXTRA_VERSION"

# Cross-check the string we are about to promise against the header the build
# actually generated, rather than trusting our own arithmetic.
FFVER_H="$WORK_DIR/build-$OS-$ARCH/libavutil/ffversion.h"
if [ -f "$FFVER_H" ]; then
  actual="$(sed -n 's/^#define FFMPEG_VERSION "\(.*\)"$/\1/p' "$FFVER_H")"
  [ "$actual" = "$AV_VERSION_INFO" ] || die "av_version_info mismatch:
  manifest would claim '$AV_VERSION_INFO'
  ffversion.h says      '$actual'
Fix --extra-version in scripts/build-ffmpeg.sh or EXTRA_VERSION here."
else
  warn "ffversion.h not found at $FFVER_H -- cannot cross-check av_version_info"
fi

# Hash every shipped binary so a consumer (or an auditor) can prove the file
# it loaded is the file we published.
artifacts_json() {
  local first=1 f rel
  printf '{\n'
  for f in $(cd "$INSTALL" && find bin lib -type f \
               \( -name '*.dll' -o -name '*.exe' -o -name '*.so.*' \
                  -o -name '*.dylib' -o -name 'ffmpeg' -o -name 'ffprobe' \) \
               2>/dev/null | sort); do
    [ -f "$INSTALL/$f" ] || continue
    rel="$f"
    [ $first -eq 1 ] || printf ',\n'
    first=0
    printf '      "%s": "%s"' "$rel" "$(sha256_of "$INSTALL/$rel")"
  done
  printf '\n    }'
}

LOCK_SHA="$(sha256_of "$LOCK_FILE")"

cat > "$INSTALL/manifest.json" <<JSON
{
  "schema": "tas-ffmpeg/manifest/1",

  "_readme": [
    "Machine-readable identity of this FFmpeg build. Both nelux and",
    "TheAnimeScripter should assert against it at startup.",
    "There is NO --build-suffix: nelux's bundled libraries and TAS's",
    "ffmpeg_shared libraries share file names, so whichever loads first in a",
    "process serves both. That is safe ONLY while they are the same build.",
    "Assert av_version_info and soname_majors; fail loudly on mismatch."
  ],

  "ffmpeg": {
    "version": "$FFMPEG_VERSION",
    "tag": "$FFMPEG_TAG",
    "commit": "$FFMPEG_COMMIT",
    "tarball_sha256": "$FFMPEG_SHA256",
    "extra_version": "$EXTRA_VERSION"
  },

  "av_version_info": "$AV_VERSION_INFO",

  "soname_majors": {
    "avcodec": $SONAME_AVCODEC,
    "avdevice": $SONAME_AVDEVICE,
    "avfilter": $SONAME_AVFILTER,
    "avformat": $SONAME_AVFORMAT,
    "avutil": $SONAME_AVUTIL,
    "swresample": $SONAME_SWRESAMPLE,
    "swscale": $SONAME_SWSCALE
  },

  "platform": { "os": "$OS", "arch": "$ARCH" },

  "licensing": {
    "spdx": "GPL-2.0-or-later",
    "gpl": true,
    "version3": false,
    "nonfree": false,
    "note": "GPL because libx264 and libx265 are linked. --enable-version3 is deliberately NOT set; see flags/ffmpeg.flags."
  },

  "provenance": {
    "versions_lock_sha256": "$LOCK_SHA",
    "configure_command": "share/tas-ffmpeg/configure-command.txt",
    "config_header": "share/tas-ffmpeg/config.h",
    "corresponding_source": "tas-ffmpeg-$FFMPEG_VERSION-corresponding-source.tar.xz"
  },

  "artifacts_sha256": $(artifacts_json)
}
JSON

log "wrote $INSTALL/manifest.json (av_version_info = $AV_VERSION_INFO)"
