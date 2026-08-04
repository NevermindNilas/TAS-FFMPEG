#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/package.sh
#
# Turns $OUT_DIR/<os>-<arch>/ into a distributable archive in $DIST_DIR,
# WITH the licence texts that make redistribution lawful.
#
# GPL COMPLIANCE -- this is not optional decoration.
#   Because we link libx264 and libx265, the binaries are GPL-2.0-or-later.
#   Distributing them obliges us to (a) ship the licence text and (b) offer
#   the complete corresponding source. (a) is this script; (b) is
#   scripts/corresponding-source.sh, and the release publishes both.
#
#   Every archive contains licenses/ with, at minimum:
#     ffmpeg/COPYING.GPLv2, COPYING.GPLv3, COPYING.LGPLv2.1, COPYING.LGPLv3,
#             LICENSE.md, CREDITS
#     x264/COPYING          (GPLv2)
#     x265/COPYING          (GPLv2)
#     libvpx, libaom, dav1d, SVT-AV1, opus, zimg, zlib, libvpl, AMF,
#     nv-codec-headers     -- each project's own LICENSE/COPYING
#   plus LICENSING.md summarising the effective terms and the source offer.
# ---------------------------------------------------------------------------
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_lock

OS="$(detect_os)"
ARCH="${TARGET_ARCH:-$(detect_arch)}"
INSTALL="$OUT_DIR/$OS-$ARCH"
NAME="$(artifact_name "$OS" "$ARCH")"
STAGE="$BUILD_ROOT/stage/$NAME"

[ -d "$INSTALL" ] || die "nothing built at $INSTALL"

rm -rf "$STAGE"; mkdir -p "$STAGE" "$DIST_DIR"

# --- payload ---------------------------------------------------------------
# Layout mirrors BtbN's *-gpl-shared archives so
# Theanimescripter/src/infra/getFFMPEG.py:316-335 (which flattens bin/* into
# ffmpeg_shared/) keeps working with only a URL + SHA256 change:
#     <root>/bin/     ffmpeg, ffprobe, and on Windows the seven DLLs
#     <root>/lib/     import libs / .so / .dylib, .def files, pkgconfig
#     <root>/include/ libav*/ headers  (nelux compiles against these)
#     <root>/licenses/
#     <root>/manifest.json
cp -r "$INSTALL/bin"     "$STAGE/bin"
cp -r "$INSTALL/lib"     "$STAGE/lib"
cp -r "$INSTALL/include" "$STAGE/include"
[ -d "$INSTALL/share/tas-ffmpeg" ] && { mkdir -p "$STAGE/share"; cp -r "$INSTALL/share/tas-ffmpeg" "$STAGE/share/"; }
cp "$INSTALL/manifest.json" "$STAGE/manifest.json"

# On non-Windows the shared libraries live in lib/; ffmpeg/ffprobe find them
# through the $ORIGIN / @loader_path rpath set in build-ffmpeg.sh.

# --- licences --------------------------------------------------------------
L="$STAGE/licenses"
mkdir -p "$L/ffmpeg"
FF_SRC="$WORK_DIR/ffmpeg-$FFMPEG_VERSION"
for f in COPYING.GPLv2 COPYING.GPLv3 COPYING.LGPLv2.1 COPYING.LGPLv3 LICENSE.md CREDITS; do
  [ -f "$FF_SRC/$f" ] && cp "$FF_SRC/$f" "$L/ffmpeg/"
done

# copy_license <dirname> <source-tree> -- copies every licence-ish file found.
copy_license() {
  local name="$1" src="$2" f found=0
  [ -d "$src" ] || { warn "no source tree for $name at $src -- LICENCE NOT SHIPPED"; return; }
  mkdir -p "$L/$name"
  for f in COPYING COPYING.txt COPYING.md LICENSE LICENSE.txt LICENSE.md \
           LICENCE licence.txt NOTICE PATENTS PATENTS.md AUTHORS COPYRIGHT; do
    if [ -f "$src/$f" ]; then cp "$src/$f" "$L/$name/"; found=1; fi
  done
  # Some projects tuck them in a subdirectory.
  for f in "$src"/LICENSE* "$src"/COPYING* "$src"/licenses/*; do
    [ -f "$f" ] && { cp "$f" "$L/$name/" 2>/dev/null && found=1; }
  done
  [ "$found" -eq 1 ] || warn "no licence file found for $name in $src -- INVESTIGATE, do not publish"
}

# license_fallback <name> <source-tree>
# For components that ship NO standalone licence file. Returns non-zero if it
# has nothing to offer, so the caller still hard-fails.
#
# There is exactly one such component today, and it is a real one: verified by
# running this script against the fetched sources, which is how it was found.
license_fallback() {
  local name="$1" src="$2" h out
  case "$name" in
    nv-codec-headers)
      # nv-codec-headers has no COPYING, no LICENSE and no NOTICE anywhere in
      # the tree -- only a Makefile, a README, ffnvcodec.pc.in and
      # include/ffnvcodec/*.h. Each header opens with its own MIT-style notice
      # that begins "This copyright notice applies to this header file only",
      # and the notices are NOT all identical (the NVIDIA-authored
      # nvEncodeAPI.h differs from the FFmpeg-authored dynlink_* ones).
      #
      # MIT requires that "the above copyright notice and this permission
      # notice shall be included in all copies or substantial portions of the
      # Software", and these headers are compiled into libavcodec on Windows
      # and Linux -- so the notices have to travel with the binaries. Extract
      # them verbatim rather than hand-transcribing one and hoping it covers
      # all five.
      out="$L/$name/LICENSE.txt"
      mkdir -p "$L/$name"
      : > "$out"
      {
        echo "nv-codec-headers ships no standalone licence file."
        echo
        echo "Every header carries its own MIT-style notice, reproduced below"
        echo "VERBATIM, one section per header, exactly as published at the"
        echo "commit pinned in versions.lock (NVCODEC_COMMIT)."
        echo
      } >> "$out"
      for h in "$src"/include/ffnvcodec/*.h; do
        [ -f "$h" ] || continue
        {
          echo "==================================================================="
          echo "include/ffnvcodec/$(basename "$h")"
          echo "==================================================================="
          awk '/^\/\*/{inc=1} inc{print} /\*\//{if(inc) exit}' "$h"
          echo
        } >> "$out"
      done
      [ -f "$src/README" ] && cp "$src/README" "$L/$name/"
      # Only a success if we actually captured a notice.
      grep -q 'Permission is hereby granted' "$out"
      ;;
    *) return 1 ;;
  esac
}

# --- which components to collect: DERIVED FROM versions.lock ---------------
#
# This was a hand-written list, and it drifted exactly the way hand-written
# lists do. openh264 and libvmaf became real, linked dependencies and were
# never added, so every archive shipped their code with no licence text.
# gmp/nettle/gnutls were gated on `[ "$OS" = "linux" ]` and read from
# $WORK_DIR, so they were missing from any archive built where build-deps.sh
# had not unpacked them. Under the GPL, under-inclusion is the violation; the
# script's only response was a warn() that nothing acts on.
#
# The list is now computed from the pins (scripts/lib/common.sh
# lock_dep_keys), and a component with NO licence file is a HARD FAILURE.
#
# We collect EVERY pinned component on EVERY platform, rather than gating on
# which ones this platform links. Over-inclusion is legally safe, has no size
# cost worth mentioning (a few tens of KB of text), and -- the real reason --
# removes the second list that would otherwise have to be kept in step with
# the per-platform skips in build-deps.sh. licenses/README.txt (written below)
# states plainly that the set is a superset and points at
# share/tas-ffmpeg/configure-command.txt for what THIS binary actually
# contains.
#
# For tarball-distributed components the licence files live in the unpacked
# tree. build-deps.sh only unpacks them on platforms that build them, so where
# that tree is absent we unpack the pinned tarball into a scratch directory
# instead. That keeps the collection platform-independent.
LIC_TMP="$BUILD_ROOT/.license-unpack"
rm -rf "$LIC_TMP"

lic_rc=0
lic_count=0
while IFS=' ' read -r prefix kind; do
  [ -n "$prefix" ] || continue
  name="$(dep_dir "$prefix")"
  case "$kind" in
    git)
      src="$SRC_DIR/$name"
      ;;
    tarball)
      src="$WORK_DIR/$name"
      if [ ! -d "$src" ]; then
        t="$SRC_DIR/$(dep_tarball "$prefix")"
        if [ -f "$t" ]; then
          src="$LIC_TMP/$name"
          mkdir -p "$src"
          # --strip-components=1 mirrors how build-deps.sh unpacks these.
          tar -C "$src" --strip-components=1 -xf "$t"
        else
          src="$SRC_DIR/$name"   # will not exist -> reported below
        fi
      fi
      ;;
  esac
  copy_license "$name" "$src"
  # NB: not `ls | wc -l` -- ls on a missing directory exits non-zero and this
  # script runs under `set -o pipefail`, so that would abort here instead of
  # reporting the missing licence.
  count_licences() {
    if [ -d "$L/$1" ]; then find "$L/$1" -type f | wc -l | tr -d '[:space:]'; else echo 0; fi
  }
  after="$(count_licences "$name")"
  if [ "$after" = "0" ] && [ -d "$src" ]; then
    if license_fallback "$name" "$src"; then
      log "  $name: no standalone licence file upstream -- notice extracted from source"
      after="$(count_licences "$name")"
    fi
  fi
  if [ "$after" = "0" ]; then
    printf '\033[1;31m[LICENCE MISSING]\033[0m %s (pinned as %s_* in versions.lock) -- no licence file collected from %s\n' "$name" "$prefix" "$src" >&2
    lic_rc=1
  else
    lic_count=$((lic_count+1))
  fi
done < <(lock_dep_keys)

rm -rf "$LIC_TMP"

[ "$lic_rc" -eq 0 ] || die "one or more pinned components have NO licence text in this archive.
These binaries are GPL-2.0-or-later (libx264 + libx265 are linked) and also
link LGPL components (GnuTLS, libiconv). Shipping them without every
component's licence is a distribution licence violation. Run
scripts/fetch-sources.sh, then re-run this script."

# Guard against the derivation silently yielding nothing.
[ "$lic_count" -ge 15 ] || die "only $lic_count component licences were collected -- the
lock-derived dependency inventory did not parse. Refusing to publish."
log "collected licences for $lic_count pinned components (derived from versions.lock)"

cat > "$L/README.txt" <<EOF
Licences shipped with tas-ffmpeg $FFMPEG_VERSION ($OS/$ARCH)
============================================================

This directory contains the licence text of EVERY third-party component
pinned in versions.lock -- which is a SUPERSET of what this particular
binary links. The set is deliberately not pruned per platform: an
over-inclusive licence directory is harmless, an under-inclusive one is a
distribution violation, and pruning would mean maintaining a second list
that can drift out of step with the build.

Components that are NOT linked on every platform:

  gnutls, gmp, nettle   Linux only. Windows uses Schannel and macOS uses
                        SecureTransport, both supplied by the OS.
  libiconv              Windows only. glibc and macOS's libSystem provide
                        iconv themselves.
  bzip2, xz             Windows and Linux only. macOS provides both in
                        /usr/lib.
  libvpl (oneVPL), AMF  Windows and Linux x86_64 only. No aarch64 or macOS
                        runtime exists.
  nv-codec-headers      Everywhere except macOS.

For the authoritative list of what THIS binary contains, read
  ../share/tas-ffmpeg/configure-command.txt   (the literal ./configure line)
  ../share/tas-ffmpeg/config.h                (the resulting feature set)
or run  bin/ffmpeg -version  and read its "configuration:" line.

The effective licence of the binaries, and the written offer of complete
corresponding source, are in LICENSING.md beside this file.
EOF

# The human-readable summary + the written source offer.
sed -e "s|@FFMPEG_VERSION@|$FFMPEG_VERSION|g" \
    -e "s|@FFMPEG_TAG@|$FFMPEG_TAG|g" \
    -e "s|@FFMPEG_COMMIT@|$FFMPEG_COMMIT|g" \
    -e "s|@X264_COMMIT@|$X264_COMMIT|g" \
    -e "s|@X265_TAG@|$X265_TAG|g" \
    "$REPO_ROOT/docs/LICENSING.md.in" > "$L/LICENSING.md"
cp "$REPO_ROOT/versions.lock" "$L/versions.lock"

# --- archive ---------------------------------------------------------------
( cd "$BUILD_ROOT/stage"
  case "$OS" in
    windows) rm -f "$DIST_DIR/$NAME.zip";     zip -qr9 "$DIST_DIR/$NAME.zip" "$NAME" ;;
    *)       rm -f "$DIST_DIR/$NAME.tar.xz";  tar -cJf "$DIST_DIR/$NAME.tar.xz" "$NAME" ;;
  esac )

# --- checksums -------------------------------------------------------------
# Idempotent: replace this archive's line rather than appending to whatever is
# already there. Plain `>>` duplicated every entry on a repeated local run
# (`./scripts/build.sh` twice), producing a SHA256SUMS that `sha256sum -c`
# reports as several passing lines for the same file -- and, once an archive
# changed between runs, as one passing and one FAILING line for it.
#
# CI's release job recomputes SHA256SUMS from scratch over the collected
# artefacts, so this file is authoritative only for local runs; that is
# exactly why it has to be correct without a clean tree.
( cd "$DIST_DIR"
  for f in "$NAME".zip "$NAME".tar.xz; do
    [ -f "$f" ] || continue
    if [ -f SHA256SUMS ]; then
      grep -v "[[:space:]]$f\$" SHA256SUMS > SHA256SUMS.tmp || true
    else
      : > SHA256SUMS.tmp
    fi
    printf '%s  %s\n' "$(sha256_of "$f")" "$f" >> SHA256SUMS.tmp
    mv SHA256SUMS.tmp SHA256SUMS
  done )

log "packaged $DIST_DIR/$NAME.(zip|tar.xz)"
