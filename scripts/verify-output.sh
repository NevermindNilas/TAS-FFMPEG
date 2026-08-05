#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/verify-output.sh <install-dir>
#
# Post-build assertions. Every check here exists because the failure it
# catches is SILENT: the build succeeds, the archive publishes, and the
# breakage surfaces on a user's machine days later.
#
# The governing idea: flags/*.flags record what we ASKED configure for. That
# is not the same as what we GOT. --disable-autodetect, a missing header, a
# pkg-config that resolved to nothing, a component renamed between FFmpeg
# releases -- each of those makes configure quietly hand back less, with a
# zero exit status. So every assertion below interrogates the BUILT ARTEFACT,
# not the flag list.
#
#   1. All seven libraries exist and their real SONAME / install-name /
#      filename carries the major from versions.lock (which matches
#      D:\Nelux\tools\ffmpeg.lock: avcodec 62, avdevice 62, avfilter 11,
#      avformat 62, avutil 60, swresample 6, swscale 9).
#   2. ffmpeg and ffprobe exist AND EXECUTE -- TAS hard-fails without both
#      (Theanimescripter/src/cli/startup.py:81). Running them also proves the
#      shared libraries resolve, which a file-existence check does not.
#   3. av_version_info() is exactly "<version>-tas". Both consumers are told
#      to assert this at startup (README.md#drift, manifest.json); if the
#      build stops producing it, that contract silently becomes a no-op.
#   4. The licence is GPL and NOT nonfree and NOT version3.
#   5. EVERY component in flags/required-components.txt is present in the
#      built binary, on the platforms it applies to. This is the highest-value
#      check in the repo: it is what turns "we think the flags are right" into
#      "the build proves it".
#   6. Threading. --disable-autodetect turns THREADS_LIST off.
#   7. Windows: the .def files nelux needs (Nelux/CMakeLists.txt:313), plus an
#      import allowlist -- which is what catches an accidentally dynamic
#      zlib1.dll / libwinpthread-1.dll / libx264-*.dll and would make the
#      nelux wheel unimportable.
#   8. Linux: no GLIBC symbol newer than 2.28 (auditwheel rejects the whole
#      nelux manylinux_2_28 wheel otherwise), plus the same import allowlist
#      applied to DT_NEEDED -- and, on x86_64, a POSITIVE pair of assertions
#      about VAAPI: that libva/libva-drm/libdrm appear in NO DT_NEEDED, and
#      that VAAPI is nevertheless compiled in and still reaching libva through
#      the Implib.so stub. Stated in both directions on purpose: absence alone
#      is also what a build that silently lost QSV looks like.
#   9. macOS: the same import allowlist applied to otool -L.
# ---------------------------------------------------------------------------
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_lock

INSTALL="${1:?usage: verify-output.sh <install-dir>}"
OS="$(detect_os)"
ARCH="${TARGET_ARCH:-$(detect_arch)}"
PLATFORM="$OS/$ARCH"
fail=0
bad() { printf '\033[1;31m[VERIFY FAIL]\033[0m %s\n' "$*" >&2; fail=1; }
ok()  { printf '\033[1;32m[ok]\033[0m %s\n' "$*" >&2; }

ALL_LIBS="avcodec avdevice avfilter avformat avutil swresample swscale"
REQ_FILE="$REPO_ROOT/flags/required-components.txt"
CFG="$INSTALL/share/tas-ffmpeg/config.h"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

case "$OS" in
  windows) EXE=".exe" ;;
  *)       EXE="" ;;
esac
FFMPEG="$INSTALL/bin/ffmpeg$EXE"
FFPROBE="$INSTALL/bin/ffprobe$EXE"

log "verifying $INSTALL  (platform $PLATFORM)"

# ===========================================================================
# 1. library set + SONAME majors
#
# The FILENAME is the contract downstream hardcodes, but the real SONAME /
# install-name is what the dynamic loader binds against, and they can
# disagree. Both are checked where the platform has both.
# ===========================================================================
soname_for() {
  case "$1" in
    avcodec) echo "$SONAME_AVCODEC" ;; avdevice) echo "$SONAME_AVDEVICE" ;;
    avfilter) echo "$SONAME_AVFILTER" ;; avformat) echo "$SONAME_AVFORMAT" ;;
    avutil) echo "$SONAME_AVUTIL" ;; swresample) echo "$SONAME_SWRESAMPLE" ;;
    swscale) echo "$SONAME_SWSCALE" ;;
  esac
}
expected_artifact() {  # <lib> <major> -> exact basename we require
  case "$OS" in
    windows) echo "$1-$2.dll" ;;
    linux)   echo "lib$1.so.$2" ;;
    macos)   echo "lib$1.$2.dylib" ;;
  esac
}
artifact_dir() { case "$OS" in windows) echo "$INSTALL/bin" ;; *) echo "$INSTALL/lib" ;; esac; }

for l in $ALL_LIBS; do
  want="$(soname_for "$l")"
  exp="$(expected_artifact "$l" "$want")"
  path="$(artifact_dir)/$exp"
  if [ ! -e "$path" ]; then
    bad "missing $exp. Downstream hardcodes these names (Nelux/src/Nelux/FFmpegDelayLoad.cpp:15-21, Nelux/tools/ffmpeg.lock:89-119); a soname bump breaks both consumers at load time."
    continue
  fi
  case "$OS" in
    linux)
      if command -v objdump >/dev/null 2>&1; then
        # NOTE: awk must read objdump to EOF. The obvious spelling here is
        # `awk '/SONAME/{print $2; exit}'`, and it made round 9 die on Linux
        # with exit code 141 (128+SIGPIPE) before printing a single [ok]:
        # awk's early exit closes the pipe, objdump takes SIGPIPE, `set -o
        # pipefail` adopts 141 as the pipeline status and `set -e` kills the
        # script. macOS never hit it because its branch uses `tail -1`, which
        # reads to EOF. Take the first match with a flag instead of exiting.
        got="$(objdump -p "$path" 2>/dev/null | awk '/SONAME/{if(!f){print $2; f=1}}')"
        [ "$got" = "$exp" ] || bad "$exp has DT_SONAME '$got', expected '$exp'"
      fi ;;
    macos)
      if command -v otool >/dev/null 2>&1; then
        got="$(basename "$(otool -D "$path" 2>/dev/null | tail -1 | tr -d '[:space:]')")"
        [ "$got" = "$exp" ] || bad "$exp has install-name basename '$got', expected '$exp'"
      fi ;;
  esac
  ok "$l major $want -- $exp"
done

# ===========================================================================
# 2. programs exist AND run
# ===========================================================================
for p in "$FFMPEG" "$FFPROBE"; do
  if [ ! -f "$p" ]; then
    bad "MISSING $(basename "$p") -- Theanimescripter/src/cli/startup.py:81 hard-fails without it"
  elif ! "$p" -hide_banner -version >/dev/null 2>&1; then
    bad "$(basename "$p") exists but will not RUN. Usually an unresolved shared library: check the rpath (\$ORIGIN/../lib on Linux, @loader_path/../lib on macOS) or a missing DLL beside the exe."
  else
    ok "program runs: $(basename "$p")"
  fi
done
RUNNABLE=0
[ -x "$FFMPEG" ] && "$FFMPEG" -hide_banner -version >/dev/null 2>&1 && RUNNABLE=1

# ffprobe's json writer is what every metadata call in TAS uses
# (autoclip.py:74-85, probe.ts:152-154, ffmpegBridge.ts:371-377).
if [ "$RUNNABLE" -eq 1 ] && [ -x "$FFPROBE" ]; then
  if "$FFPROBE" -hide_banner -v quiet -print_format json -show_program_version 2>/dev/null | grep -q '"program_version"'; then
    ok "ffprobe -print_format json works"
  else
    bad "ffprobe cannot emit -print_format json -- TAS parses JSON from ffprobe in three places (autoclip.py:85, probe.ts:154, ffmpegBridge.ts:377)"
  fi
fi

# ===========================================================================
# 3. av_version_info() == "<version>-tas"
#
# --extra-version=tas (build-ffmpeg.sh) makes FFMPEG_VERSION "<version>-tas"
# via ffbuild/version.sh:40,48. No distro, gyan or BtbN build can produce that
# string, which is precisely why both consumers are told to assert it at
# startup. If it regresses, that assertion silently starts passing on somebody
# else's FFmpeg.
# ===========================================================================
WANT_VERSION="$FFMPEG_VERSION-tas"
if [ "$RUNNABLE" -eq 1 ]; then
  got="$("$FFMPEG" -hide_banner -version 2>/dev/null | head -1 | awk '{print $3}')"
  if [ "$got" = "$WANT_VERSION" ]; then
    ok "av_version_info = $got"
  else
    bad "av_version_info is '$got', expected '$WANT_VERSION'. Either --extra-version=tas was lost from scripts/build-ffmpeg.sh, or FFMPEG_VERSION in versions.lock disagrees with the source that was actually built. manifest.json and ffmpeg-pin.lock both promise this exact string."
  fi
fi

# ===========================================================================
# 4. licence: GPL, not nonfree, not version3
# ===========================================================================
if [ "$RUNNABLE" -eq 1 ]; then
  lic="$("$FFMPEG" -hide_banner -L 2>/dev/null || true)"
  case "$lic" in
    *"not legally redistributable"*|*"nonfree"*)
      bad "the binary reports a NONFREE licence -- it cannot be distributed at all. Something enabled --enable-nonfree." ;;
    *"GNU General Public License"*)
      case "$lic" in
        *"version 3"*) bad "licence is GPL v3. --enable-version3 must not be set (flags/ffmpeg.flags); it would relicense the whole binary via configure:4773 and break combination with GPLv2-only code." ;;
        *) ok "licence is GPL v2 or later" ;;
      esac ;;
    *"Lesser General Public License"*)
      bad "licence is LGPL, not GPL -- --enable-gpl was lost, which means libx264 and libx265 are NOT in this build. Both consumers require them." ;;
    *) bad "could not determine the licence from 'ffmpeg -L'" ;;
  esac

  conf="$("$FFMPEG" -hide_banner -version 2>/dev/null | sed -n 's/^ *configuration: //p')"
  case "$conf" in *--enable-nonfree*) bad "configuration line contains --enable-nonfree" ;; esac
  case "$conf" in *--enable-version3*) bad "configuration line contains --enable-version3" ;; esac
  case "$conf" in *--enable-gpl*) ;; *) bad "configuration line does NOT contain --enable-gpl" ;; esac
fi
if [ -f "$CFG" ]; then
  grep -qE '^#define CONFIG_GPL 1$'      "$CFG" || bad "config.h: CONFIG_GPL is not 1"
  grep -qE '^#define CONFIG_NONFREE 0$'  "$CFG" || bad "config.h: CONFIG_NONFREE is not 0"
  grep -qE '^#define CONFIG_VERSION3 0$' "$CFG" || bad "config.h: CONFIG_VERSION3 is not 0"

  # --- compression + charset backends -------------------------------------
  # zlib/bzlib/lzma/iconv are all in configure's
  # EXTERNAL_AUTODETECT_LIBRARY_LIST (configure:1966-1985), so
  # --disable-autodetect turns every one of them OFF and flags/ffmpeg.flags
  # has to name them explicitly (:176-186).
  #
  # ffmpeg-8.1.2 configure:8285-8287 does `requested $lib && ! enabled $lib &&
  # die`, so a MISSING backend is a hard configure failure rather than a
  # silent feature drop -- but the flags could still be edited away, and on
  # Windows these are supplied by libraries we now build from pinned source
  # (versions.lock BZIP2_*/XZ_*/LIBICONV_*). config.h is the built artefact's
  # own answer, which is why the assertion lives here and not in the flag
  # validator.
  for c in ZLIB BZLIB LZMA ICONV; do
    grep -qE "^#define CONFIG_$c 1\$" "$CFG" \
      || bad "config.h: CONFIG_$c is not 1. Matroska track compression and header stripping, TIFF/image lzma decode and subtitle/metadata charset conversion depend on these; flags/ffmpeg.flags:176-186 asks for all four."
  done
  ok "zlib, bzlib, lzma and iconv are all enabled in the built config.h"
fi

# ===========================================================================
# 5. required components, from flags/required-components.txt
#
# Driven by a checked-in, evidence-annotated list and checked against the
# BUILT BINARY's own inventory. CLI names, not configure names -- see the
# header of that file for why the two spellings both have to be policed.
# ===========================================================================
collect() {  # collect <ffmpeg-list-flag> -> one component name per line
  case "$1" in
    encoders|decoders)
      # ' V....D libx264   libx264 H.264...'  -- flags column is 6 chars.
      "$FFMPEG" -hide_banner "-$1" 2>/dev/null \
        | awk 'length($1)==6 && $1 ~ /^[VAS][.A-Z]+$/ {print $2}' ;;
    muxers|demuxers|devices)
      # ' E mp4  MP4 ...'   /   ' D mov,mp4,m4a,3gp,3g2,mj2  QuickTime...'
      "$FFMPEG" -hide_banner "-$1" 2>/dev/null \
        | awk '$1 ~ /^[DE.]+$/ && NF>=2 && $2 ~ /^[a-z0-9_][a-z0-9_,.+-]*$/ {print $2}' ;;
    filters)
      # ' ... scale   V->V   Scale...'  -- the '->' column is the tell.
      "$FFMPEG" -hide_banner -filters 2>/dev/null \
        | awk 'NF>=3 && $3 ~ /->/ {print $2}' ;;
    protocols)
      # 'Input:' / 'Output:' headers are flush-left; names are indented.
      "$FFMPEG" -hide_banner -protocols 2>/dev/null \
        | sed -n 's/^[[:space:]][[:space:]]*\([a-z0-9_+-][a-z0-9_+-]*\)[[:space:]]*$/\1/p' ;;
    bsfs)
      # one bare name per line, after a 'Bitstream filters:' header
      "$FFMPEG" -hide_banner -bsfs 2>/dev/null \
        | sed -n 's/^\([a-z0-9_][a-z0-9_]*\)$/\1/p' ;;
  esac
}

# platform_applies "<selector>" -- see flags/required-components.txt for the
# grammar. Tokens are applied left to right; '!' subtracts.
platform_applies() {
  local sel="$1" tok neg hit match=0
  local oldifs="$IFS"
  IFS=','
  for tok in $sel; do
    IFS="$oldifs"
    neg=0
    case "$tok" in '!'*) neg=1; tok="${tok#!}" ;; esac
    hit=0
    case "$tok" in
      all)         hit=1 ;;
      "$OS")       hit=1 ;;
      "$PLATFORM") hit=1 ;;
    esac
    [ "$hit" -eq 1 ] && { if [ "$neg" -eq 1 ]; then match=0; else match=1; fi; }
    IFS=','
  done
  IFS="$oldifs"
  [ "$match" -eq 1 ]
}

if [ ! -f "$REQ_FILE" ]; then
  bad "flags/required-components.txt is MISSING -- the component contract cannot be checked. This file is the point of this script; do not publish without it."
elif [ "$RUNNABLE" -eq 0 ]; then
  bad "ffmpeg will not run, so the required-component contract could NOT be verified. Treat this build as unverified."
else
  for kind in encoders decoders muxers demuxers filters protocols bsfs devices; do
    collect "$kind" | sort -u > "$TMP/$kind"
  done
  # ffmpeg prints one demuxer as 'mov,mp4,m4a,3gp,3g2,mj2'; explode it so a
  # request for 'mp4' matches.
  tr ',' '\n' < "$TMP/demuxers" | sort -u > "$TMP/demuxers.exp"
  mv "$TMP/demuxers.exp" "$TMP/demuxers"
  tr ',' '\n' < "$TMP/muxers" | sort -u > "$TMP/muxers.exp"
  mv "$TMP/muxers.exp" "$TMP/muxers"

  checked=0; skipped=0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -z "$line" ] && continue
    set -- $line
    [ "$#" -ge 3 ] || { bad "required-components.txt: malformed line '$line' (want: <kind> <name> <platforms>)"; continue; }
    kind="$1"; name="$2"; plats="$3"
    case "$kind" in
      encoder)  haystack="$TMP/encoders"  ;;
      decoder)  haystack="$TMP/decoders"  ;;
      muxer)    haystack="$TMP/muxers"    ;;
      demuxer)  haystack="$TMP/demuxers"  ;;
      filter)   haystack="$TMP/filters"   ;;
      protocol) haystack="$TMP/protocols" ;;
      bsf)      haystack="$TMP/bsfs"      ;;
      device)   haystack="$TMP/devices"   ;;
      *) bad "required-components.txt: unknown kind '$kind' in '$line'"; continue ;;
    esac
    if ! platform_applies "$plats"; then skipped=$((skipped+1)); continue; fi
    checked=$((checked+1))
    grep -qxF -e "$name" "$haystack" \
      || bad "required $kind MISSING from the built ffmpeg: $name   (flags/required-components.txt says it applies to '$plats'; this platform is $PLATFORM)"
  done < "$REQ_FILE"

  if [ "$checked" -lt 50 ]; then
    bad "only $checked components were checked -- required-components.txt did not parse. Refusing to call this verified."
  else
    ok "component contract: $checked required components checked, $skipped not applicable to $PLATFORM (any missing one is reported above as a VERIFY FAIL)"
  fi
fi

# ===========================================================================
# 6. threading
#
# --disable-autodetect (flags/ffmpeg.flags) turns off THREADS_LIST. If a
# per-OS flag file ever loses --enable-w32threads / --enable-pthreads the
# build still SUCCEEDS and is silently single-threaded, which shows up only as
# "why is decoding 8x slower than it used to be".
# ===========================================================================
if [ -f "$CFG" ]; then
  if grep -qE '^#define (HAVE_PTHREADS|HAVE_W32THREADS) 1$' "$CFG"; then
    ok "threading enabled"
  else
    bad "NO THREADING. --disable-autodetect disabled THREADS_LIST and flags/ffmpeg.$OS.flags did not re-enable it."
  fi
else
  warn "no config.h staged at $CFG -- SKIPPED the threading and licence-header checks"
fi

# ===========================================================================
# 7-9. dependency closure
#
# One rule, three spellings: the shipped binaries may import ONLY the seven
# libav*/libsw* of this build plus libraries the target OS guarantees. Anything
# else means a pinned dependency got linked dynamically -- and neither consumer
# ships it. nelux's wheel contains only av*/sw*, so a stray libx264/libz/
# libgnutls is an ImportError on every user's machine.
# ===========================================================================
if [ "$OS" = "windows" ]; then
  for l in $ALL_LIBS; do
    ls "$INSTALL"/lib/"$l"-*.def >/dev/null 2>&1 \
      || bad "no .def for $l -- Nelux/CMakeLists.txt:313-319 FATAL_ERRORs without it"
  done
  ok ".def files present (nelux regenerates MSVC import libs from these via lib.exe /def:)"

  # AVICAP32 and MSVFW32 are genuine Windows system DLLs (System32), pulled in
  # by libavdevice's vfwcap input device -- which we ship deliberately, because
  # nelux's own test suite needs libavdevice for `-f lavfi`
  # (Nelux/tests/test_codec_container_parity.py:38-42). Round 9 flagged
  # AVICAP32.dll here; it is a false positive, not a dynamically linked
  # dependency, and neither consumer has to ship it.
  ALLOWED='^(KERNEL32|USER32|GDI32|ADVAPI32|SHELL32|OLE32|OLEAUT32|WS2_32|SECUR32|NCRYPT|BCRYPT|CRYPT32|PSAPI|SHLWAPI|MSVCRT|api-ms-win-|VCRUNTIME|UCRTBASE|MFPLAT|MFUUID|STRMIIDS|DXGI|D3D11|D3D12|D3D9|AVRT|IMM32|SETUPAPI|CFGMGR32|WINMM|DWMAPI|NORMALIZ|IPHLPAPI|USERENV|VERSION|POWRPROF|MF|MFREADWRITE|AVICAP32|MSVFW32|MSACM32)'
  if command -v objdump >/dev/null 2>&1; then
    for f in "$INSTALL"/bin/*.dll "$INSTALL"/bin/*.exe; do
      [ -e "$f" ] || continue
      while IFS= read -r dll; do
        case "$dll" in av*|sw*) continue ;; esac
        printf '%s' "$dll" | grep -qiE "$ALLOWED" \
          || bad "$(basename "$f") imports non-system DLL '$dll' -- a dependency was linked dynamically; neither consumer ships it."
      done < <(objdump -p "$f" | awk '/DLL Name:/ {print $3}')
    done
    ok "Windows import allowlist check complete"
  else
    warn "objdump not found -- SKIPPED the import allowlist check (this is the check that catches a dynamic zlib1.dll)"
  fi
fi

if [ "$OS" = "linux" ]; then
  # --- RUNPATH / RPATH must contain a LITERAL $ORIGIN -----------------------
  #
  # This check exists because the bug it catches is invisible to every other
  # check here AND to CI as a whole.
  #
  # scripts/build-ffmpeg.sh asks configure for
  #     -Wl,-rpath,'$$ORIGIN:$$ORIGIN/../lib'
  # configure:4624 copies that verbatim into ffbuild/config.mak; make turns
  # `$$` into `$`; /bin/sh then runs the link recipe. Without the single
  # quotes, sh expands the (unset) shell variable $ORIGIN to nothing and the
  # recorded runpath becomes `:/../lib` -- a silently WRONG value that the
  # linker accepts, that `ffmpeg -version` cannot reveal, and that check 2
  # above cannot catch either, because check 2 runs the binary from the
  # install tree where the loader finds the libraries by other means.
  #
  # It only fails once a consumer extracts the archive somewhere else and
  # spawns bin/ffmpeg, which is precisely what TAS does
  # (Theanimescripter/src/infra/getFFMPEG.py flattens bin/* into
  # ffmpeg_shared/). So: assert the STRING, not the behaviour.
  RPATH_TOOL=""
  if   command -v readelf >/dev/null 2>&1; then RPATH_TOOL=readelf
  elif command -v objdump >/dev/null 2>&1; then RPATH_TOOL=objdump
  fi
  if [ -n "$RPATH_TOOL" ]; then
    rp_checked=0
    for f in "$INSTALL"/bin/ffmpeg "$INSTALL"/bin/ffprobe "$INSTALL"/lib/*.so.*; do
      [ -f "$f" ] || continue
      case "$f" in *.so.*.*) continue ;; esac   # only the SONAME symlink target
      if [ "$RPATH_TOOL" = readelf ]; then
        rp="$(readelf -d "$f" 2>/dev/null | sed -n 's/.*(\(RUNPATH\|RPATH\)).*\[\(.*\)\]/\2/p')"
      else
        rp="$(objdump -p "$f" 2>/dev/null | awk '/^ *(RUNPATH|RPATH)/{print $2}')"
      fi
      rp_checked=$((rp_checked+1))
      case "$rp" in
        *'$ORIGIN'*) ;;
        '') bad "$(basename "$f") has NO DT_RUNPATH/DT_RPATH at all. --extra-ldflags=-Wl,-rpath,... was dropped from scripts/build-ffmpeg.sh; the binary will not find its sibling libraries once the archive is extracted anywhere but the build tree." ;;
        *)  bad "$(basename "$f") records runpath '$rp', which does not contain a literal \$ORIGIN. This is the shell-expansion bug: the value reached /bin/sh unquoted and sh expanded the unset \$ORIGIN to the empty string. Restore the single quotes in the linux branch of scripts/build-ffmpeg.sh." ;;
      esac
    done
    if [ "$rp_checked" -eq 0 ]; then
      bad "no ELF objects found to check for \$ORIGIN in the runpath"
    else
      ok "runpath contains a literal \$ORIGIN on all $rp_checked ELF objects"
    fi
  else
    warn "neither readelf nor objdump found -- SKIPPED the \$ORIGIN runpath check"
  fi

  if command -v objdump >/dev/null 2>&1; then
    # --- glibc floor ---
    worst=""
    for f in "$INSTALL"/lib/*.so.* "$INSTALL"/bin/*; do
      [ -f "$f" ] || continue
      v="$(objdump -T "$f" 2>/dev/null | grep -oE 'GLIBC_2\.[0-9]+' | sort -t. -k2 -n | tail -1 || true)"
      [ -n "$v" ] && worst="$(printf '%s\n%s\n' "$worst" "$v" | grep -v '^$' | sort -t. -k2 -n | tail -1)"
    done
    if [ -n "$worst" ]; then
      n="${worst#GLIBC_2.}"
      if [ "$n" -gt 28 ]; then
        bad "references $worst (> GLIBC_2.28). auditwheel will REJECT the nelux manylinux_2_28 wheel. You are not building inside the manylinux_2_28 image pinned in versions.lock (MANYLINUX_IMAGE_X86_64 / MANYLINUX_IMAGE_AARCH64)."
      else
        ok "max glibc reference is $worst (<= 2.28)"
      fi
    fi

    # --- DT_NEEDED allowlist ---
    # A deliberate SUBSET of auditwheel's manylinux_2_28 lib_whitelist, not a
    # copy of it. auditwheel also permits libz.so.1, libexpat.so.1, libX11 and
    # the rest of the X/GL set; we do NOT, because we build zlib statically on
    # purpose and neither consumer wants an X dependency. Being stricter than
    # the policy is the point: a hit here is the Linux equivalent of shipping a
    # dynamic zlib1.dll, and libx264.so.164, libgnutls.so.30, libva.so.2,
    # libvpl.so.2 and libgmp.so.10 all land here.
    #
    # libmvec.so.1 IS allowed, and was added after round 10 flagged it:
    #     [VERIFY FAIL] libavcodec.so.62 has DT_NEEDED 'libmvec.so.1'
    # It arrived with the --extra-libs=-lm added for zimg -- GCC emits calls
    # into glibc's vectorised math library when it auto-vectorises libm calls.
    # That was a FALSE POSITIVE: auditwheel's manylinux_2_28_x86_64
    # lib_whitelist lists libmvec.so.1 explicitly (pypa/auditwheel,
    # src/auditwheel/policy/manylinux-policy.json), so the nelux wheel is
    # unaffected. It ships with glibc itself, so it is present wherever
    # libc.so.6 is.
    L_ALLOWED='^(libc\.so\.6|libm\.so\.6|libmvec\.so\.1|libdl\.so\.2|librt\.so\.1|libpthread\.so\.0|libgcc_s\.so\.1|libstdc\+\+\.so\.6|libatomic\.so\.1|libnsl\.so\.1|libutil\.so\.1|libcrypt\.so\.[12]|ld-linux-x86-64\.so\.2|ld-linux-aarch64\.so\.1)$'
    for f in "$INSTALL"/lib/*.so.* "$INSTALL"/bin/ffmpeg "$INSTALL"/bin/ffprobe; do
      [ -f "$f" ] || continue
      while IFS= read -r so; do
        case "$so" in libav*|libsw*) continue ;; esac
        printf '%s' "$so" | grep -qE "$L_ALLOWED" \
          || bad "$(basename "$f") has DT_NEEDED '$so' -- outside the manylinux_2_28 policy set. A pinned dependency was linked dynamically; neither consumer ships it and auditwheel will pull it into (or reject) the nelux wheel."
      done < <(objdump -p "$f" 2>/dev/null | awk '/NEEDED/{print $2}')
    done
    ok "Linux DT_NEEDED allowlist check complete"

    # --- VAAPI is DLOPEN'd, not DT_NEEDED (part 1 of 2) --------------------
    #
    # The allowlist above already rejects libva.so.2 -- but only by OMISSION,
    # and an allowlist is one careless widening away from stopping. This says
    # it in the other direction, by name, so the diff that would break it has
    # to argue with a check that exists specifically for it.
    #
    # flags/ffmpeg.linux.flags:39 passes --enable-vaapi because QSV on Linux
    # creates a VAAPI child device, and h264_qsv / hevc_qsv / vp9_qsv are all
    # REQUIRED on this platform (flags/required-components.txt:108-110). The
    # only way to have both that and a wheel-safe dependency closure is the
    # Implib.so stub (scripts/build-deps.sh build_libva): every VA entry point
    # is a trampoline that dlopen()s the user's own libva.so.2 on first call.
    #
    # If someone reinstates libva-devel in docker/Dockerfile.manylinux_2_28,
    # deletes the `rm` of the .so in build_libva, or enables --enable-libdrm,
    # the corresponding DT_NEEDED reappears and lands here.
    if [ "$ARCH" = "x86_64" ]; then
      vaapi_dt_needed=0
      for f in "$INSTALL"/lib/*.so.* "$INSTALL"/bin/ffmpeg "$INSTALL"/bin/ffprobe; do
        [ -f "$f" ] || continue
        while IFS= read -r so; do
          case "$so" in
            libva.so.*|libva-drm.so.*|libva-x11.so.*|libdrm.so.*|libpciaccess.so.*)
              vaapi_dt_needed=1
              bad "$(basename "$f") has DT_NEEDED '$so'. The VAAPI stack must be
reached through the Implib.so stub archives, NEVER as a link-time dependency:
libva.so.2, libva-drm.so.2 and libdrm.so.2 are all outside the manylinux_2_28
policy set, so auditwheel either vendors them into nelux's wheel or rejects
it, and TAS's bin/ffmpeg will not start at all on a machine that lacks them.
Look at build_libva in scripts/build-deps.sh (is the .so still being deleted
after gen_implib?) and at docker/Dockerfile.manylinux_2_28 (did libva-devel
come back?)." ;;
          esac
        done < <(objdump -p "$f" 2>/dev/null | awk '/NEEDED/{print $2}')
      done
      [ "$vaapi_dt_needed" -eq 1 ] \
        || ok "no DT_NEEDED on libva/libva-drm/libdrm anywhere in the tree"
    fi
  else
    warn "objdump not found -- SKIPPED the glibc floor and DT_NEEDED checks on Linux"
    # The VAAPI assertion above is NOT allowed to be skipped, unlike its
    # neighbours. The failure it guards is invisible everywhere else: the
    # build succeeds, ffmpeg runs here (libva is present in the build image
    # either way), and the breakage only appears when auditwheel repairs
    # nelux's wheel in ANOTHER repository, or on a user's machine.
    [ "$ARCH" != "x86_64" ] \
      || bad "objdump is missing, so the VAAPI DT_NEEDED assertion could not run.
That check is not optional on linux/x86_64 -- install binutils in
docker/Dockerfile.manylinux_2_28. Refusing to call this build verified."
  fi

  # --- VAAPI is DLOPEN'd, not DT_NEEDED (part 2 of 2) ----------------------
  #
  # Absence of a DT_NEEDED is also what you get if VAAPI simply is not in the
  # build at all, so on its own the check above would pass a build that had
  # quietly lost QSV. These two assert the other half: that VAAPI IS compiled
  # in, and that the mechanism it reaches libva through is still the stub.
  #
  # The string test is the one that catches a stub that stopped working. The
  # generated shim (Implib.so arch/common/init.c.tpl) contains a literal
  # dlopen("libva.so.2", ...) plus an error message naming the same SONAME, so
  # the string is present in libavutil if and only if the stub was linked into
  # it. Combined with part 1 -- which independently forbids the DT_NEEDED that
  # is the only other way that string could get there -- a hit can only mean
  # the stub. A miss means someone linked the real library, dropped
  # --enable-vaapi, or upgraded libva past a SONAME bump.
  if [ "$ARCH" = "x86_64" ]; then
    if [ -f "$CFG" ]; then
      # NOTE the two different PREFIXES, which are not interchangeable and
      # cost a CI round when they were assumed to be. In ffmpeg-8.1.2's
      # configure, `vaapi` is in HWACCEL_AUTODETECT_LIBRARY_LIST, which feeds
      # CONFIG_LIST, so it is emitted as CONFIG_VAAPI. But `vaapi_drm` is in
      # SYSTEM_LIBRARIES (configure:2565-2571), which configure:2662 folds
      # into HAVE_LIST -- so it is emitted as HAVE_VAAPI_DRM and
      # CONFIG_VAAPI_DRM DOES NOT EXIST AT ALL. Asserting the latter fails on
      # every build no matter how healthy, which is exactly what round 10
      # reported and round 11 repeated. Note it never complained about
      # CONFIG_VAAPI: VAAPI was enabled the whole time.
      for c in CONFIG_VAAPI HAVE_VAAPI_DRM; do
        grep -qE "^#define $c 1\$" "$CFG" \
          || bad "config.h: $c is not 1. --enable-vaapi was requested
(flags/ffmpeg.linux.flags:39) but the built binary does not have it, so
\`-init_hw_device qsv\` will fail at runtime even though the required
h264_qsv/hevc_qsv/vp9_qsv encoders are listed as present: the QSV hwcontext
creates a VAAPI CHILD DEVICE. Most likely libva.pc or libva-drm.pc did not
resolve -- see build_libva in scripts/build-deps.sh."
      done
    fi
    AVUTIL="$INSTALL/lib/libavutil.so.$SONAME_AVUTIL"
    if [ -f "$AVUTIL" ]; then
      stub_ok=1
      for want in libva.so.2 libva-drm.so.2; do
        LC_ALL=C grep -a -q -F "$want" "$AVUTIL" || {
          stub_ok=0
          bad "libavutil.so.$SONAME_AVUTIL does not contain the string '$want'.
The Implib.so stub is what puts it there (it is the argument to the generated
dlopen), so this means VAAPI is no longer reaching libva through the stub.
Either --enable-vaapi was lost, or libva was linked for real -- and if it was
linked for real the DT_NEEDED check above should also have fired. If libva
bumped its SONAME past .so.2, the stubs are now dlopening a library no
distribution ships and build_libva's hardcoded libva.so.2 needs revisiting
together with this assertion."
        }
      done
      if [ "$stub_ok" -eq 1 ]; then
        ok "VAAPI reaches libva through the Implib.so stub (lazy dlopen of libva.so.2 / libva-drm.so.2)"
      fi
    else
      bad "no libavutil.so.$SONAME_AVUTIL to check the VAAPI stub against"
    fi
  fi
fi

if [ "$OS" = "macos" ]; then
  # --- LC_RPATH must carry @loader_path/../lib -----------------------------
  # The macOS twin of the $ORIGIN assertion above. @loader_path needs no shell
  # quoting so it has never been corrupted, but the check costs nothing and
  # the failure mode is identical: bin/ffmpeg cannot find ../lib/libav*.dylib
  # once the archive is extracted outside the build tree.
  if command -v otool >/dev/null 2>&1; then
    rp_checked=0
    for f in "$INSTALL"/bin/ffmpeg "$INSTALL"/bin/ffprobe; do
      [ -f "$f" ] || continue
      rp_checked=$((rp_checked+1))
      if otool -l "$f" 2>/dev/null | grep -A2 LC_RPATH | grep -q '@loader_path/../lib'; then
        :
      else
        bad "$(basename "$f") has no LC_RPATH containing '@loader_path/../lib'. --install-name-dir=@rpath needs a matching -Wl,-rpath; see the macos branch of scripts/build-ffmpeg.sh."
      fi
    done
    [ "$rp_checked" -eq 0 ] || ok "LC_RPATH carries @loader_path/../lib"
  fi

  if command -v otool >/dev/null 2>&1; then
    # System libraries live under /usr/lib and /System/Library/Frameworks;
    # our own are referenced through @rpath. Everything else -- notably
    # anything under /opt/homebrew or /usr/local -- means a Homebrew library
    # leaked into the artefact, which would break on any other Mac.
    M_ALLOWED='^(/usr/lib/|/System/Library/Frameworks/|@rpath/lib(av|sw)|@loader_path/)'
    for f in "$INSTALL"/lib/*.dylib "$INSTALL"/bin/ffmpeg "$INSTALL"/bin/ffprobe; do
      [ -f "$f" ] || continue
      while IFS= read -r dep; do
        printf '%s' "$dep" | grep -qE "$M_ALLOWED" \
          || bad "$(basename "$f") links '$dep' -- outside /usr/lib, the system frameworks and @rpath. A Homebrew build tool leaked into the artefact; it will not exist on a user's Mac."
      done < <(otool -L "$f" 2>/dev/null | tail -n +2 | awk '{print $1}')
    done
    ok "macOS otool -L allowlist check complete"
  else
    warn "otool not found -- SKIPPED the macOS link allowlist check"
  fi
fi

[ "$fail" -eq 0 ] || die "verification FAILED for $INSTALL"
log "verification PASSED for $INSTALL"
