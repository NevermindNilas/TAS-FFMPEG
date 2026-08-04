#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/corresponding-source.sh
#
# Builds the CORRESPONDING SOURCE archive that the GPL source offer points at.
# Published once per release, alongside the per-platform binary archives.
#
# GPL-2.0 section 3 requires "the complete corresponding machine-readable
# source code ... plus any associated interface definition files, plus the
# scripts used to control compilation and installation of the executable."
# So this archive contains all three:
#
#   src/        pristine, hash-verified source of FFmpeg and EVERY dependency
#               that ends up in the binaries (git trees checked out at the
#               pinned commit, with .git/ stripped so the tarball is stable)
#   build/      this entire repository -- versions.lock, flags/, scripts/,
#               docker/, .github/ -- i.e. "the scripts used to control
#               compilation"
#   configure-command-<os>-<arch>.txt   the literal ./configure line used
#
# Run this AFTER scripts/fetch-sources.sh. It does not need a compiler and can
# be produced on any one platform for the whole release.
# ---------------------------------------------------------------------------
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_lock

NAME="tas-ffmpeg-$FFMPEG_VERSION-corresponding-source"
STAGE="$BUILD_ROOT/stage-src/$NAME"

[ -d "$SRC_DIR" ] || die "no sources at $SRC_DIR -- run scripts/fetch-sources.sh first"

rm -rf "$STAGE"; mkdir -p "$STAGE/src" "$STAGE/build" "$DIST_DIR"

# --- 1. FFmpeg: ship the original signed tarball, byte for byte ------------
# Better than a re-tar of the extracted tree: the recipient can verify it
# against ffmpeg.org's own PGP signature, independently of us.
cp "$SRC_DIR/ffmpeg-$FFMPEG_VERSION.tar.xz" "$STAGE/src/"
[ -f "$SRC_DIR/ffmpeg-$FFMPEG_VERSION.tar.xz.asc" ] \
  && cp "$SRC_DIR/ffmpeg-$FFMPEG_VERSION.tar.xz.asc" "$STAGE/src/"

# --- 2. Every dependency, at its pinned commit -----------------------------
copy_src() {
  local name="$1" dir="$SRC_DIR/$1" commit
  [ -d "$dir" ] || { warn "missing source tree: $name -- SOURCE OFFER WOULD BE INCOMPLETE"; return 1; }
  commit="$(git -C "$dir" rev-parse HEAD 2>/dev/null || echo unknown)"
  log "staging $name @ $commit"
  mkdir -p "$STAGE/src/$name"
  # `git archive` gives a clean tree at exactly HEAD with no .git and no
  # build residue, which keeps this archive reproducible.
  if [ -d "$dir/.git" ]; then
    git -C "$dir" archive --format=tar HEAD | tar -C "$STAGE/src/$name" -xf -
    # Submodules (SVT-AV1 and libvpl both use them) are not covered by
    # `git archive`, so copy them explicitly.
    git -C "$dir" submodule --quiet foreach --recursive \
      'mkdir -p "'"$STAGE"'/src/'"$name"'/$displaypath" && git archive --format=tar HEAD | tar -C "'"$STAGE"'/src/'"$name"'/$displaypath" -xf -' 2>/dev/null || true
  else
    cp -r "$dir" "$STAGE/src/$name"
  fi
  printf '%s %s\n' "$name" "$commit" >> "$STAGE/src/COMMITS.txt"
}

# The set of components is DERIVED FROM versions.lock (scripts/lib/common.sh
# lock_dep_keys), never hand-listed here.
#
# It used to be hand-listed, and it drifted: openh264 and libvmaf were linked
# into every binary while this loop had never heard of them, and the
# gmp/nettle/gnutls tarballs that fetch-sources.sh downloads had no copy step
# at all. The `rc=1` guard could not notice, because it only verified that the
# names ALREADY in the list resolved -- a list that omits a component passes
# its own check every time. Since GnuTLS is LGPL-2.1-or-later and x264/x265
# are GPL-2.0, publishing that archive would have been an actual licence
# violation rather than an untidy one.
#
# Now the pins ARE the list. Adding a *_REPO or *_URL to versions.lock adds it
# here automatically; failing to teach dep_dir() where it lives is a hard
# error (see scripts/lib/common.sh).
#
# Tarball-distributed components (gmp is Mercurial upstream; GnuTLS, Nettle,
# bzip2, xz and libiconv publish release tarballs as THE canonical artefact)
# ship as the pristine archive, which also lets the recipient re-verify the
# SHA256 recorded in versions.lock.
#
# EVERY component is shipped on EVERY platform's release, including ones a
# given platform does not link (GnuTLS is Linux-only, libvpl/AMF are x86_64
# Windows+Linux). One source archive serves the whole release, so it has to be
# a superset; per-platform pruning would be a second list to drift.
rc=0
staged_count=0
while IFS=' ' read -r prefix kind; do
  [ -n "$prefix" ] || continue
  name="$(dep_dir "$prefix")"
  case "$kind" in
    git)
      copy_src "$name" || rc=1
      staged_count=$((staged_count+1))
      ;;
    tarball)
      t="$(dep_tarball "$prefix")"
      if [ -f "$SRC_DIR/$t" ]; then
        log "staging $name tarball $t"
        cp "$SRC_DIR/$t" "$STAGE/src/"
        printf '%s (tarball) %s\n' "$t" "$(sha256_of "$SRC_DIR/$t")" >> "$STAGE/src/COMMITS.txt"
        staged_count=$((staged_count+1))
      else
        warn "missing $SRC_DIR/$t ($prefix) -- SOURCE OFFER WOULD BE INCOMPLETE"
        rc=1
      fi
      ;;
    *) die "lock_dep_keys returned unknown kind '$kind' for $prefix" ;;
  esac
done < <(lock_dep_keys)

[ "$rc" -eq 0 ] || die "one or more pinned components have no source in $SRC_DIR --
refusing to publish an incomplete source offer. Run scripts/fetch-sources.sh.
The binaries in this release are GPL-2.0-or-later (x264 + x265) and link
LGPL components (GnuTLS, libiconv); an incomplete corresponding-source
archive is a licence violation, not a packaging nit."

# Guard against the derivation itself silently yielding nothing (a renamed
# lock file, a broken sed). "0 errors" over 0 components is not a pass.
[ "$staged_count" -ge 15 ] || die "only $staged_count components were staged from versions.lock --
the lock-derived dependency inventory did not parse. Refusing to publish."
log "staged $staged_count pinned components (derived from versions.lock)"

# --- 3. The build system itself -------------------------------------------
# "the scripts used to control compilation and installation".
for p in versions.lock README.md LICENSE flags scripts docker .github docs tools; do
  [ -e "$REPO_ROOT/$p" ] && cp -r "$REPO_ROOT/$p" "$STAGE/build/"
done

# --- 4. The literal configure lines, per platform, if built ---------------
for d in "$OUT_DIR"/*/; do
  [ -f "$d/share/tas-ffmpeg/configure-command.txt" ] || continue
  cp "$d/share/tas-ffmpeg/configure-command.txt" \
     "$STAGE/configure-command-$(basename "$d").txt"
done

cat > "$STAGE/README.txt" <<EOF
Corresponding source for tas-ffmpeg $FFMPEG_VERSION
===================================================

This archive is the "complete corresponding source" referred to by the GPL
notice in the binary archives (see licenses/LICENSING.md there).

  src/ffmpeg-$FFMPEG_VERSION.tar.xz
        The unmodified upstream FFmpeg release tarball. We apply NO patches.
        tag    $FFMPEG_TAG
        commit $FFMPEG_COMMIT
        sha256 $FFMPEG_SHA256
        A .asc PGP signature from ffmpeg.org is included where available so
        you can verify this against upstream without trusting us.

  src/<dep>/
        Each third-party library at the exact commit it was built from.
        src/COMMITS.txt lists every name and commit hash.
        None of them are patched either.

  build/
        The complete build system: versions.lock (the pins), flags/ (the
        configure flags, one per line with the reason each is present),
        scripts/ (fetch, build, verify, package), docker/ (the
        manylinux_2_28 image used for the Linux build) and .github/ (CI).

  configure-command-<os>-<arch>.txt
        The literal ./configure invocation used for each published binary.

To rebuild:  cd build && ./scripts/build.sh
EOF

( cd "$BUILD_ROOT/stage-src" && tar -cJf "$DIST_DIR/$NAME.tar.xz" "$NAME" )

# Idempotent, for the same reason as scripts/package.sh: `>>` duplicated this
# line on every repeated local run.
( cd "$DIST_DIR"
  if [ -f SHA256SUMS ]; then
    grep -v "[[:space:]]$NAME\.tar\.xz\$" SHA256SUMS > SHA256SUMS.tmp || true
  else
    : > SHA256SUMS.tmp
  fi
  printf '%s  %s\n' "$(sha256_of "$NAME.tar.xz")" "$NAME.tar.xz" >> SHA256SUMS.tmp
  mv SHA256SUMS.tmp SHA256SUMS )

log "corresponding source: $DIST_DIR/$NAME.tar.xz"
