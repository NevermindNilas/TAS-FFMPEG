#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/fetch-sources.sh
#
# Fetches and VERIFIES every pinned input into $SRC_DIR, then unpacks FFmpeg
# into $WORK_DIR. Every artefact is checked against versions.lock; a mismatch
# is a hard failure, never a warning.
#
# This script is also what makes the corresponding-source archive possible:
# after it runs, $SRC_DIR contains the complete, verified source of every GPL
# component we ship. scripts/corresponding-source.sh just packages it.
# ---------------------------------------------------------------------------
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_lock

require_lock FFMPEG_VERSION FFMPEG_URL FFMPEG_SHA256 FFMPEG_COMMIT \
             NVCODEC_TAG NVCODEC_COMMIT NVCODEC_REPO \
             X264_COMMIT X264_REPO X265_TAG X265_COMMIT X265_REPO \
             DAV1D_TAG DAV1D_COMMIT DAV1D_REPO \
             SVTAV1_TAG SVTAV1_COMMIT SVTAV1_REPO \
             AOM_TAG AOM_COMMIT AOM_REPO \
             VPX_TAG VPX_COMMIT VPX_REPO \
             OPUS_TAG OPUS_COMMIT OPUS_REPO \
             ZIMG_TAG ZIMG_COMMIT ZIMG_REPO \
             ZLIB_TAG ZLIB_COMMIT ZLIB_REPO \
             LIBVPL_TAG LIBVPL_COMMIT LIBVPL_REPO \
             AMF_TAG AMF_COMMIT AMF_REPO \
             OPENH264_TAG OPENH264_COMMIT OPENH264_REPO \
             VMAF_TAG VMAF_COMMIT VMAF_REPO \
             GMP_VERSION GMP_URL GMP_SHA256 \
             NETTLE_VERSION NETTLE_URL NETTLE_SHA256 \
             GNUTLS_VERSION GNUTLS_URL GNUTLS_SHA256 \
             BZIP2_VERSION BZIP2_URL BZIP2_SHA256 \
             XZ_VERSION XZ_URL XZ_SHA256 \
             LIBICONV_VERSION LIBICONV_URL LIBICONV_SHA256

mkdir -p "$SRC_DIR" "$WORK_DIR"

# --- FFmpeg ----------------------------------------------------------------
FF_TARBALL="$SRC_DIR/ffmpeg-$FFMPEG_VERSION.tar.xz"
fetch_tarball "$FFMPEG_URL" "$FF_TARBALL" "$FFMPEG_SHA256"

# Belt and braces: ffmpeg.org publishes no .sha256, only a PGP signature.
# The SHA256 in versions.lock is OURS; the signature is upstream's. Verify it
# when gpg is present so a compromised mirror cannot pass a hash we recorded
# from that same compromised mirror.
if command -v gpg >/dev/null 2>&1 && [ -n "${FFMPEG_SIG_URL:-}" ]; then
  curl -fsSL --retry 3 -o "$SRC_DIR/$(basename "$FFMPEG_SIG_URL")" "$FFMPEG_SIG_URL" || true
  if [ -f "$SRC_DIR/$(basename "$FFMPEG_SIG_URL")" ]; then
    if gpg --list-keys "$FFMPEG_GPG_FPR" >/dev/null 2>&1 \
       || gpg --keyserver keyserver.ubuntu.com --recv-keys "$FFMPEG_GPG_FPR" >/dev/null 2>&1; then
      if gpg --verify "$SRC_DIR/$(basename "$FFMPEG_SIG_URL")" "$FF_TARBALL" >/dev/null 2>&1; then
        log "PGP signature on the FFmpeg tarball verified against $FFMPEG_GPG_FPR"
      else
        die "FFmpeg tarball PGP signature verification FAILED"
      fi
    else
      warn "could not obtain FFmpeg release key $FFMPEG_GPG_FPR; skipping PGP check (SHA256 still enforced)"
    fi
  fi
else
  warn "gpg not available; relying on the SHA256 pin alone"
fi

if [ ! -f "$WORK_DIR/ffmpeg-$FFMPEG_VERSION/configure" ]; then
  log "unpacking FFmpeg $FFMPEG_VERSION"
  rm -rf "$WORK_DIR/ffmpeg-$FFMPEG_VERSION"
  tar -C "$WORK_DIR" -xf "$FF_TARBALL"
fi

# Assert the SONAME majors match versions.lock BEFORE building anything.
# If upstream ever changes one, every downstream consumer that hardcodes a
# DLL/so name breaks -- we want to know here, not after a 40-minute build.
# NOTE ON WHERE THE MAJOR ACTUALLY LIVES -- do not "simplify" this back to a
# single header.
#
# Six of the seven libraries declare LIB<X>_VERSION_MAJOR in
# lib<x>/version_major.h. libavutil does NOT: its version_major.h exists but
# is INTENTIONALLY EMPTY, and says so in its own comment --
#
#     /* This file is intentionally empty; it's only kept to fulfill make
#      * dependencies for ffbuild/libversion.sh. It is not installed. */
#
# -- while LIBAVUTIL_VERSION_MAJOR 60 lives in libavutil/version.h:81.
# (Verified against the unpacked 8.1.2 tarball, not assumed.)
#
# So an `[ -f "$hdr" ] || hdr=...version.h` fallback can never fire for
# avutil: the file is present, merely empty. The old code then ran a grep
# pipeline that matched nothing, and because this script runs under
# `set -euo pipefail` the failing pipeline inside a command substitution
# aborted the shell BEFORE reaching `die` -- so the very first CI job exited
# non-zero with no diagnostic at all, and `needs: validate` silently skipped
# both the build and the source jobs.
#
# We therefore search BOTH headers for the value, in order, and fail loudly
# with the list of files searched if neither yields one.
check_soname() {
  local lib="$1" want="$2" upper base hdr got
  base="$WORK_DIR/ffmpeg-$FFMPEG_VERSION/lib$lib"
  upper="$(printf '%s' "$lib" | tr '[:lower:]' '[:upper:]')"
  got=""
  for hdr in "$base/version_major.h" "$base/version.h"; do
    [ -f "$hdr" ] || continue
    # `sed -n ...p` exits 0 whether or not it matched, so this cannot trip
    # `set -e`; and the `q` keeps it a single command (no pipe, hence no
    # SIGPIPE-under-pipefail hazard) so a miss is data, not a crash.
    got="$(sed -n "/^#define LIB${upper}_VERSION_MAJOR[[:space:]]/{s/.*[[:space:]]\\([0-9][0-9]*\\).*/\\1/p;q;}" "$hdr")"
    if [ -n "$got" ]; then break; fi
  done
  if [ -z "$got" ]; then
    die "cannot determine the SONAME major for lib$lib.
Searched for '#define LIB${upper}_VERSION_MAJOR <n>' in
    $base/version_major.h
    $base/version.h
Neither file defines it. Upstream moved the macro (again) -- fix
check_soname() in scripts/fetch-sources.sh. Refusing to build without
having verified the ABI majors that both consumers hardcode."
  fi
  [ "$got" = "$want" ] || die "SONAME DRIFT: lib$lib major is $got, versions.lock says $want.
Downstream consumers hardcode these. Update versions.lock AND tell both
consumers before proceeding."
}
check_soname avcodec    "$SONAME_AVCODEC"
check_soname avdevice   "$SONAME_AVDEVICE"
check_soname avfilter   "$SONAME_AVFILTER"
check_soname avformat   "$SONAME_AVFORMAT"
check_soname avutil     "$SONAME_AVUTIL"
check_soname swresample "$SONAME_SWRESAMPLE"
check_soname swscale    "$SONAME_SWSCALE"
log "SONAME majors match versions.lock"

# --- Dependencies ----------------------------------------------------------
fetch_git "$NVCODEC_REPO" "$NVCODEC_COMMIT" "$SRC_DIR/nv-codec-headers" "$NVCODEC_TAG"
fetch_git "$X264_REPO"    "$X264_COMMIT"    "$SRC_DIR/x264"             "$X264_TAG"
fetch_git "$X265_REPO"    "$X265_COMMIT"    "$SRC_DIR/x265"             "$X265_TAG"
fetch_git "$DAV1D_REPO"   "$DAV1D_COMMIT"   "$SRC_DIR/dav1d"            "$DAV1D_TAG"
fetch_git "$SVTAV1_REPO"  "$SVTAV1_COMMIT"  "$SRC_DIR/svt-av1"          "$SVTAV1_TAG"
fetch_git "$AOM_REPO"     "$AOM_COMMIT"     "$SRC_DIR/aom"              "$AOM_TAG"
fetch_git "$VPX_REPO"     "$VPX_COMMIT"     "$SRC_DIR/libvpx"           "$VPX_TAG"
fetch_git "$OPUS_REPO"    "$OPUS_COMMIT"    "$SRC_DIR/opus"             "$OPUS_TAG"
fetch_git "$ZLIB_REPO"    "$ZLIB_COMMIT"    "$SRC_DIR/zlib"             "$ZLIB_TAG"

# zimg backs the zscale filter, which TAS needs (ffmpegSettings.py:797).
fetch_git "$ZIMG_REPO"    "$ZIMG_COMMIT"    "$SRC_DIR/zimg"             "$ZIMG_TAG"

# OpenH264 -- last entry of nelux's default-encoder probe
# (Nelux/src/Nelux/python/VideoEncoder.cpp:46,49,51).
fetch_git "$OPENH264_REPO" "$OPENH264_COMMIT" "$SRC_DIR/openh264"       "$OPENH264_TAG"

# libvmaf -- backs the `libvmaf` filter that Nelux/tests/test_software_encoders
# .py:181 hard-requires (it RAISES at :198, it does not skip).
fetch_git "$VMAF_REPO"    "$VMAF_COMMIT"    "$SRC_DIR/vmaf"             "$VMAF_TAG"

# Windows + Linux only, but again: always fetched, for the source archive.
fetch_git "$LIBVPL_REPO"  "$LIBVPL_COMMIT"  "$SRC_DIR/libvpl"           "$LIBVPL_TAG"
fetch_git "$AMF_REPO"     "$AMF_COMMIT"     "$SRC_DIR/AMF"              "$AMF_TAG"

# --- TLS stack (Linux only at build time, always fetched for the archive) ---
# See versions.lock: GnuTLS is the ONLY GPL-compatible TLS backend FFmpeg
# 8.1.2 will accept (configure:7382-7383 rejects LibreSSL outright under
# --enable-gpl, :7493-7494 rejects OpenSSL in both directions).
# Tarballs, not git: gmp is Mercurial upstream, and GnuTLS/Nettle publish
# release tarballs as the canonical artefact.
fetch_tarball "$GMP_URL"    "$SRC_DIR/$(dep_tarball GMP)"    "$GMP_SHA256"
fetch_tarball "$NETTLE_URL" "$SRC_DIR/$(dep_tarball NETTLE)" "$NETTLE_SHA256"
fetch_tarball "$GNUTLS_URL" "$SRC_DIR/$(dep_tarball GNUTLS)" "$GNUTLS_SHA256"

# --- bzip2 / xz / libiconv (Windows + Linux at build time, always fetched) --
# See versions.lock BZIP2_*/XZ_*/LIBICONV_* for why these are built from
# source instead of taken from MSYS2 and from AlmaLinux's bzip2-devel /
# xz-devel: on Windows GNU ld prefers the .dll.a and the DLLs would import
# libbz2-1.dll / liblzma-5.dll / libiconv-2.dll; on Linux those packages ship
# only the shared library, so libavformat.so.62 grows a DT_NEEDED outside the
# manylinux_2_28 policy set. Both break the nelux wheel.
fetch_tarball "$BZIP2_URL"    "$SRC_DIR/$(dep_tarball BZIP2)"    "$BZIP2_SHA256"
fetch_tarball "$XZ_URL"       "$SRC_DIR/$(dep_tarball XZ)"       "$XZ_SHA256"
fetch_tarball "$LIBICONV_URL" "$SRC_DIR/$(dep_tarball LIBICONV)" "$LIBICONV_SHA256"

# --- completeness guard ----------------------------------------------------
# Everything above is written out by hand so each pin can carry its own
# reasoning. That readability is worth keeping, but it also means a pin added
# to versions.lock can be silently left unfetched -- and an unfetched
# dependency is a GPL corresponding-source hole, because
# scripts/corresponding-source.sh packages whatever is in $SRC_DIR.
#
# So: assert that EVERY component versions.lock pins is now present, using the
# same lock-derived inventory the packaging scripts use. Adding a pin without
# adding a fetch for it fails here, before any build time is spent.
missing=""
while IFS=' ' read -r prefix kind; do
  [ -n "$prefix" ] || continue
  case "$kind" in
    git)
      [ -d "$SRC_DIR/$(dep_dir "$prefix")/.git" ] \
        || missing="$missing
  $prefix -> $SRC_DIR/$(dep_dir "$prefix")  (git checkout)" ;;
    tarball)
      [ -f "$SRC_DIR/$(dep_tarball "$prefix")" ] \
        || missing="$missing
  $prefix -> $SRC_DIR/$(dep_tarball "$prefix")  (tarball)" ;;
  esac
done < <(lock_dep_keys)
[ -z "$missing" ] || die "versions.lock pins components that this script never fetched:$missing
Every pin must be fetched here, or the corresponding-source archive is
incomplete and the GPL source offer is a lie. Add the fetch above."

log "all sources fetched and verified into $SRC_DIR"
