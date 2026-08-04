#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/validate-flags.sh [os ...]        (default: windows linux macos)
#
# Checks every flag in flags/*.flags against the ACTUAL pinned FFmpeg source.
# Catches the two failure modes that otherwise produce a successful build with
# a silently missing feature:
#
#   1. An option name that does not exist. configure rejects these loudly, so
#      they only cost a CI round-trip -- but this catches them in seconds and
#      for all three OSes at once, from any host.
#   2. A COMPONENT name that does not exist. `--enable-encoder=mov_text` is
#      accepted by configure's option parser and then does NOTHING, because
#      the configure-time name is `movtext`. This class of bug ships.
#
# Requires scripts/fetch-sources.sh to have run. Needs bash + awk, no compiler.
# ---------------------------------------------------------------------------
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
. "$REPO_ROOT/scripts/lib/flags.sh"
load_lock

FF_SRC="$WORK_DIR/ffmpeg-$FFMPEG_VERSION"
[ -x "$FF_SRC/configure" ] || die "FFmpeg source not unpacked at $FF_SRC -- run scripts/fetch-sources.sh first"

CACHE="$BUILD_ROOT/.flagcache"
mkdir -p "$CACHE"

# Valid option names, derived from `configure --help`. configure accepts both
# --enable-X and --disable-X for anything it lists in either form, so the
# prefix is normalised away. (Verified: `--enable-schannel` works even though
# --help only prints `--disable-schannel`, because schannel is a CONFIG_LIST
# entry.)
#
# `--help` alone is NOT sufficient. configure accepts --enable-X for every
# identifier in its CONFIG_LIST, and several of those are never printed by
# --help: `--enable-cuda` is valid (configure:3336 `cuda_deps="ffnvcodec"`,
# and cuda is in HWACCEL_AUTODETECT_LIBRARY_LIST) but --help only shows
# --disable-cuda-llvm and --enable-cuda-nvcc. So we ALSO harvest every
# identifier from configure's own `*_LIST="..."` blocks, translating `_` to
# `-` the way configure's option parser does.
if [ ! -s "$CACHE/options.txt" ]; then
  log "extracting valid option names from $FF_SRC/configure"
  {
    ( cd "$FF_SRC" && ./configure --help ) 2>&1 \
      | grep -oE '^[[:space:]]+--[a-z0-9][a-z0-9-]*' \
      | sed -e 's/^[[:space:]]*//' -e 's/^--\(enable\|disable\)-//' -e 's/^--//'
    # Identifiers inside any `SOMETHING_LIST="` ... `"` block.
    awk '
      /^[A-Z0-9_]+_LIST="/ { inlist=1; next }
      inlist && /^"/       { inlist=0; next }
      inlist               { for (i=1;i<=NF;i++) if ($i ~ /^[a-z0-9_]+$/) print $i }
    ' "$FF_SRC/configure" | tr '_' '-'
  } | sort -u > "$CACHE/options.txt"
fi

for list in encoders decoders muxers demuxers parsers bsfs protocols filters hwaccels indevs outdevs; do
  if [ ! -s "$CACHE/$list.txt" ]; then
    ( cd "$FF_SRC" && ./configure --list-"$list" ) 2>/dev/null \
      | tr -s ' \t' '\n' | grep -v '^$' | sort -u > "$CACHE/$list.txt"
  fi
done

rc=0
check_one() {
  local file="$1" flag="$2" name kind
  case "$flag" in
    --enable-encoder=*|--disable-encoder=*)   kind=encoders   ;;
    --enable-decoder=*|--disable-decoder=*)   kind=decoders   ;;
    --enable-muxer=*|--disable-muxer=*)       kind=muxers     ;;
    --enable-demuxer=*|--disable-demuxer=*)   kind=demuxers   ;;
    --enable-parser=*|--disable-parser=*)     kind=parsers    ;;
    --enable-bsf=*|--disable-bsf=*)           kind=bsfs       ;;
    --enable-protocol=*|--disable-protocol=*) kind=protocols  ;;
    --enable-filter=*|--disable-filter=*)     kind=filters    ;;
    --enable-hwaccel=*|--disable-hwaccel=*)   kind=hwaccels   ;;
    --enable-indev=*|--disable-indev=*)       kind=indevs     ;;
    --enable-outdev=*|--disable-outdev=*)     kind=outdevs    ;;
    # Free-form value options: only the option name is checkable.
    --build-suffix=*|--prefix=*|--extra-*=*|--pkg-config-flags=*|--arch=*|\
    --cc=*|--cxx=*|--nm=*|--ar=*|--ranlib=*|--strip=*|--target-os=*|\
    --install-name-dir=*|--sysroot=*|--toolchain=*|--optflags=*|\
    --host-cc=*|--windres=*|--x86asmexe=*|--pkg-config=*|--extra-version=*)
      return 0 ;;
    *)
      name="${flag#--}"; name="${name#enable-}"; name="${name#disable-}"; name="${name%%=*}"
      if ! grep -qxF -e "$name" "$CACHE/options.txt"; then
        printf '  %s: UNKNOWN OPTION  %s\n' "$(basename "$file")" "$flag"
        rc=1
      fi
      return 0 ;;
  esac
  name="${flag#*=}"
  if ! grep -qxF -e "$name" "$CACHE/$kind.txt"; then
    printf '  %s: UNKNOWN %s  %s\n' "$(basename "$file")" "${kind%s}" "$flag"
    printf '        (configure names differ from CLI names: movtext not mov_text, libaom_av1 not libaom-av1, libvpx_vp9 not libvpx-vp9)\n'
    rc=1
  fi
}

validate_file() {
  local f="$1" line
  [ -f "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -z "$line" ] && continue
    check_one "$f" "$line"
  done < "$f"
}

# Every file that can apply to this OS. Validation is per-NAME, so the
# concatenation order is irrelevant here and we can simply sweep the portable
# file, the per-OS file and EVERY per-arch file for that OS -- which means a
# typo in flags/ffmpeg.linux.arm64.flags is caught even on a CI job that never
# builds aarch64.
seen_any=0
oses="${*:-windows linux macos}"
for o in $oses; do
  log "validating flags for $o"
  validate_file "$REPO_ROOT/flags/ffmpeg.flags"
  validate_file "$REPO_ROOT/flags/ffmpeg.$o.flags"
  for af in "$REPO_ROOT/flags/ffmpeg.$o".*.flags; do
    [ -e "$af" ] || continue
    log "  + $(basename "$af")"
    validate_file "$af"
  done
  seen_any=1
done
[ "$seen_any" -eq 1 ] || die "no OS given and no default list -- nothing validated"

# Guard against the whole loop silently no-op'ing (a bad glob, a renamed
# directory). If flags/ffmpeg.flags itself did not parse into at least one
# flag, something is structurally wrong and "0 errors" is a lie.
if [ "$(grep -cE '^[[:space:]]*--' "$REPO_ROOT/flags/ffmpeg.flags")" -lt 5 ]; then
  die "flags/ffmpeg.flags contains almost no flags -- refusing to report success"
fi

[ "$rc" -eq 0 ] || die "flag validation FAILED (see above)"
log "all flags valid against FFmpeg $FFMPEG_VERSION"
