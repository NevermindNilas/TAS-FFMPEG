#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/build-ffmpeg.sh
#
# Configures and builds FFmpeg for the current platform. There is ONE build
# that serves both consumers.
#
# All feature flags come from flags/*.flags (see scripts/lib/flags.sh); ONLY
# toolchain and path flags are computed here, because those are machine facts
# and cannot be reviewed as static text.
#
# Installs into $OUT_DIR/<os>-<arch>/.
# ---------------------------------------------------------------------------
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
. "$REPO_ROOT/scripts/lib/flags.sh"
load_lock

OS="$(detect_os)"
ARCH="${TARGET_ARCH:-$(detect_arch)}"
JOBS="$(nproc_portable)"

FF_SRC="$WORK_DIR/ffmpeg-$FFMPEG_VERSION"
FF_BUILD="$WORK_DIR/build-$OS-$ARCH"
INSTALL="$OUT_DIR/$OS-$ARCH"

# Linux runpath, in two halves. RPATH_REAL is what ships; RPATH_PLACEHOLDER is
# what the linker records so patchelf can overwrite it in place rather than
# rewrite the program headers. The placeholder MUST stay at least as long as
# the real value or patchelf falls back to the header-rewriting path that
# corrupted bin/ffmpeg -- see the long note in the linux branch below and the
# assertion after the patchelf loop.
RPATH_REAL='$ORIGIN:$ORIGIN/../lib'
# Keep the placeholder readable: FFmpeg bakes the whole configure line into
# .rodata, so this string is visible in `ffmpeg -buildconf` on every shipped
# binary. It only has to be at least as long as RPATH_REAL (22 chars).
RPATH_PLACEHOLDER='/nonexistent/tas-ffmpeg-runpath-placeholder-patched-after-install'

[ -x "$FF_SRC/configure" ] || die "run scripts/fetch-sources.sh first"

rm -rf "$FF_BUILD" "$INSTALL"
mkdir -p "$FF_BUILD" "$INSTALL"

export PKG_CONFIG_PATH="$PREFIX_DIR/lib/pkgconfig:$PREFIX_DIR/lib64/pkgconfig:${PKG_CONFIG_PATH:-}"

# --- toolchain / path flags (machine-dependent, hence not in flags/) --------
declare -a TOOLCHAIN
TOOLCHAIN=(
  "--prefix=$INSTALL"
  "--extra-cflags=-I$PREFIX_DIR/include"
  "--extra-cxxflags=-I$PREFIX_DIR/include"
  "--extra-ldflags=-L$PREFIX_DIR/lib"
  # Static deps carry transitive libs (x265 needs -lstdc++, SVT-AV1 -lm and
  # -lpthread). --static makes pkg-config emit Libs.private.
  "--pkg-config-flags=--static"
  # Stamped into `ffmpeg -version` and into av_version_info(). This is what
  # the manifest.json version assertion is checked against downstream -- see
  # scripts/make-manifest.sh and README.md#drift.
  "--extra-version=tas"
)

case "$OS" in
  windows)
    # nelux regenerates MSVC import libs from the .def files we ship
    # (Nelux/CMakeLists.txt:313-336) with `lib.exe /def:`, because
    # doc/platform.texi warns that dlltool-generated import libs "will fail
    # during runtime" without /OPT:NOREF. Nothing extra is needed here --
    # configure:6165 already installs $(SLIBNAME_WITH_MAJOR:.dll=.def) into
    # LIBDIR for every library -- but scripts/verify-output.sh asserts they
    # are present, because silently losing them breaks nelux's CMake configure
    # with a confusing error.
    #
    # -static-libgcc keeps libgcc_s_seh-1.dll out of the DLLs' import table.
    TOOLCHAIN+=("--extra-ldflags=-static-libgcc")
    # -static-libstdc++ is the companion, but note it is NOT sufficient on its
    # own and is NOT what actually keeps libstdc++-6.dll out: gcc's
    # -static-libstdc++ only rewrites the IMPLICIT -lstdc++ that the *g++*
    # driver adds, and FFmpeg links with gcc against an EXPLICIT -lstdc++ that
    # arrives from pkg-config (x265.pc, zimg.pc, ...). The real fix is in
    # scripts/build-deps.sh, where cxx_runtime_lib() writes `-l:libstdc++.a`
    # into those .pc files so GNU ld cannot pick libstdc++.dll.a. This flag
    # stays because it is correct for anything gcc DOES add implicitly.
    TOOLCHAIN+=("--extra-ldflags=-static-libstdc++")
    # bzip2's bzlib.h declares its entry points as function POINTERS on _WIN32
    # unless BZ_EXPORT is defined (bzlib.h:78-95) -- a configuration that
    # compiles, links, passes configure's check_lib, and then calls a null
    # pointer at runtime. build-deps.sh compiles bzip2 itself with the same
    # define. See versions.lock BZIP2_*.
    TOOLCHAIN+=("--extra-cflags=-DBZ_EXPORT")
    # iconv: mingw has no iconv in libc, and configure's
    # --disable-autodetect path forces the LIBC probe and never reaches the
    # -liconv fallback --
    #     configure:4727-4731   disabled iconv || enable libc_iconv
    #     configure:7838-7842   if enabled libc_iconv; then
    #                               check_func_headers iconv.h iconv
    #                           elif enabled iconv; then ... -liconv ... fi
    #     configure:8285-8287   requested $lib && ! enabled $lib && die
    # -- so without this the Windows build DIES at configure with
    # "ERROR: iconv requested but not found". test_ld appends $extralibs to
    # every probe link line, so --extra-libs is exactly the lever that makes
    # the libc probe link against the static libiconv.a built by
    # build-deps.sh. -l:libwinpthread.a is belt-and-braces: it forces GNU ld
    # to take the static archive for any pthread reference that leaks out of
    # a C++ dependency, instead of resolving it to libwinpthread-1.dll (which
    # neither consumer ships and which verify-output.sh's import allowlist
    # rejects). Nothing is pulled from an archive whose symbols are unused.
    TOOLCHAIN+=("--extra-libs=-liconv")
    # ...but only if the toolchain really ships the static archive. Every
    # configure PROBE links with $extralibs (configure's test_ld), so naming a
    # library that does not exist would fail every probe at once and bury the
    # real cause under a hundred unrelated "not found" messages.
    WINPTHREAD_A="$("${CC:-gcc}" -print-file-name=libwinpthread.a 2>/dev/null || echo libwinpthread.a)"
    if [ -f "$WINPTHREAD_A" ]; then
      TOOLCHAIN+=("--extra-libs=-l:libwinpthread.a")
    else
      warn "no static libwinpthread.a in this toolchain; if any C++ dependency
pulls in pthreads, the DLLs will import libwinpthread-1.dll and
scripts/verify-output.sh's import allowlist will (correctly) fail the build."
    fi
    ;;
  linux)
    # *** -lpthread IS MANDATORY HERE, AND x265 IS WHY. ***
    #
    # manylinux_2_28 is AlmaLinux 8 -- glibc 2.28, which still keeps
    # pthread_create/pthread_join in libpthread.so.0. (glibc only folded them
    # into libc.so.6 in 2.34, which is why this class of failure is invisible
    # on every modern distro and on macOS, where pthreads live in libSystem.)
    #
    # configure gets each dependency's link line from pkg-config, and x265's
    # CMake DELIBERATELY strips the C runtime names out of it:
    #     x265/source/CMakeLists.txt:145    list(APPEND PLATFORM_LIBS pthread)
    #     x265/source/CMakeLists.txt:1124-1126
    #         list(REMOVE_ITEM PLIBLIST "-lc" "-lpthread" ...)
    # so `pkg-config --static --libs x265` returns
    #     -L... -lx265 -lstdc++ -lm -lgcc_s -lgcc -lrt -ldl
    # with no -lpthread, while libx265.a really does reference pthread_create
    # (x265/source/common/threading.cpp:147) and pthread_mutex_init
    # (common/threading.h:319,349,437).
    #
    # configure does NOT make up the difference. Its own pthread probe at
    # configure:7152-7155 ends in `add_allcflags -pthread`, and add_allcflags
    # only touches CFLAGS/CXXFLAGS/OBJCFLAGS -- while test_ld links with
    #     $ld $LDFLAGS $LDEXEFLAGS $flags -o $TMPE $TMPO $libs $extralibs
    # (no CFLAGS). So the probe for libx265 at configure:7432 links without
    # any pthread at all and dies with the least useful message in the file:
    #     ERROR: x265 not found using pkg-config
    # -- identical to the message you get when x265.pc is missing entirely,
    # which is what sent the previous round chasing the wrong bug.
    #
    # --extra-libs lands in $extralibs, which IS on every probe link line, so
    # this is the lever. It is also exactly what FFmpeg's own CentOS
    # compilation guide prescribes (`--extra-libs="-lpthread -lm"`), for this
    # reason. Every other C++ dependency we build keeps pthread in its .pc
    # (x264/configure:1728, and meson emits it for openh264/libvmaf/dav1d),
    # which is why x265 alone failed. libpthread.so.0 is inside the
    # manylinux_2_28 policy set and is already allowed by
    # scripts/verify-output.sh's DT_NEEDED allowlist, so this adds no new
    # runtime dependency -- avutil already pulls it in via pthreads_extralibs.
    # -lm is here for the SAME REASON, one dependency later. zimg.pc does not
    # list it either, and static libzimg.a genuinely needs it -- round 7 got
    # past x265 and died on the next probe with, verbatim from config.log:
    #     ld: .../libzimg.a(libzimg_internal_la-libm_wrapper.o): undefined
    #         reference to symbol 'sin@@GLIBC_2.2.5'
    #     ld: /lib64/libm.so.6: error adding symbols: DSO missing from
    #         command line
    #     ERROR: zimg >= 2.7.0 not found using pkg-config
    # Note the FFmpeg guide quoted above prescribes BOTH ("-lpthread -lm");
    # the previous round took only half of it and paid a full round for the
    # other half. libm.so.6 is in the manylinux_2_28 policy set and already in
    # verify-output.sh's DT_NEEDED allowlist, so this adds no runtime
    # dependency either.
    TOOLCHAIN+=("--extra-libs=-lpthread -lm")

    # --- a PLACEHOLDER runpath, so patchelf never has to grow the ELF -------
    #
    # This is not the real runpath and it must never ship. It exists so that
    # by the time patchelf runs there is ALREADY a DT_RUNPATH string in
    # .dynstr with room to spare, which lets patchelf overwrite it BYTE FOR
    # BYTE instead of rewriting the program headers.
    #
    # That distinction is the whole bug. With no runpath at link time,
    # patchelf had to add one, and on a non-PIE ET_EXEC that means relocating
    # PT_PHDR and inserting a PT_LOAD. It got that wrong on bin/ffmpeg and
    # right on bin/ffprobe -- same tool, same invocation, different section
    # layout -- and the result was a binary whose headers make the dynamic
    # loader itself segfault:
    #
    #     Program received signal SIGSEGV
    #     #0  dl_main (...) at rtld.c:1834
    #     #1  _dl_sysdep_start ... #3 _dl_start
    #
    # i.e. inside ld-linux while it walks the phdrs, before any library
    # initialiser runs. That is why LD_BIND_NOW made no difference and why
    # the Implib.so stub was never the culprit -- nothing of ours had
    # executed yet. The pre/post-patchelf smoke tests below pinned it: the
    # same binary ran before patchelf touched it and died after.
    #
    # patchelf takes the in-place path when the new value FITS in the old
    # one, so the placeholder just has to be at least as long as
    # '$ORIGIN:$ORIGIN/../lib' (22 chars). It is padded far past that so a
    # future change to the real runpath cannot silently push it back onto the
    # header-rewriting path.
    #
    # There is NO `$` anywhere in this value, which is what makes it safe to
    # pass through --extra-ldflags at all -- see the long note below about
    # configure's append() eval turning `$$` into a PID. The literal $ORIGIN
    # still goes in with patchelf, after install, where nothing evals it.
    #
    # --enable-new-dtags keeps this a DT_RUNPATH (what patchelf would have
    # created), not the transitive DT_RPATH.
    TOOLCHAIN+=("--extra-ldflags=-Wl,--enable-new-dtags,-rpath,$RPATH_PLACEHOLDER")

    # Built inside manylinux_2_28 -- see docker/Dockerfile.manylinux_2_28.
    # $ORIGIN so ffmpeg/ffprobe find ../lib without LD_LIBRARY_PATH.
    #
    # *** THE QUOTING HERE IS LOAD-BEARING. DO NOT "TIDY" IT. ***
    #
    # The literal four characters  $ O R I  ... must survive TWO expansions
    # before the linker ever sees them:
    #
    #   1. configure:4624 (`--extra-ldflags=*) add_ldflags $optval`) copies the
    #      value verbatim into ffbuild/config.mak as `LDFLAGS=... <value>`.
    #   2. make expands `$$` -> `$` when it uses $(LDFLAGS) in the recipe.
    #   3. /bin/sh then runs that recipe line -- and expands `$ORIGIN`, which
    #      is an ordinary (unset) shell variable, to the EMPTY STRING.
    #
    # With the previous `\$\$ORIGIN:\$\$ORIGIN/../lib` the runpath recorded in
    # the ELF was therefore `:/../lib`. Nothing in CI executes the Linux
    # binaries from a relocated tree, so this published cleanly and then broke
    # on the user's machine:
    #     ffmpeg: error while loading shared libraries: libavdevice.so.62
    # ...which is exactly the failure TAS hits when it spawns our ffmpeg out of
    # its extracted ffmpeg_shared/ directory.
    #
    # *** THE RPATH IS NOT SET HERE. IT IS SET AFTER INSTALL, WITH patchelf.
    # *** DO NOT "RESTORE" AN --extra-ldflags=-Wl,-rpath LINE HERE.
    #
    # Two attempts died on this, in two different ways, and the second one
    # revealed why no spelling can work. FFmpeg's configure implements
    # add_ldflags via append():
    #
    #     append(){ var=$1; shift; eval "$var=\"\$$var $*\""; }
    #
    # That `eval` RE-EXPANDS the value, so `$$` becomes configure's own PID
    # at step 1 -- before make or sh are ever reached. Round 10 recorded
    #     RUNPATH = '92877ORIGIN:92877ORIGIN/../lib'
    # where 92877 is a process id. The earlier attempt, without the single
    # quotes, produced `:/../lib` instead when sh expanded the unset $ORIGIN.
    # Escaping hard enough to survive an eval, then make's `$$` -> `$`, then
    # sh, is possible in principle and unreadable in practice -- and the two
    # failure modes above are both silent in every check except the explicit
    # RUNPATH assertion in scripts/verify-output.sh.
    #
    # patchelf runs once, on the finished binaries, with no quoting layers
    # between the string and the ELF. See the patch_rpath block below.
    ;;
  macos)
    # *** SAME --disable-autodetect ICONV TRAP AS WINDOWS ABOVE. ***
    # macOS does NOT provide iconv in libc: the entry points live in
    # /usr/lib/libiconv.2.dylib and you must say -liconv. configure's normal
    # autodetect path copes --
    #     configure:7840-7841  elif enabled iconv; then
    #                              check_func_headers iconv.h iconv ||
    #                              check_lib iconv iconv.h iconv -liconv
    # -- because check_lib sets iconv_extralibs, which configure:4310 folds
    # into avcodec_extralibs. But we pass --disable-autodetect, and
    # configure:4727-4731 then forces
    #     disabled iconv || enable libc_iconv
    # which takes the OTHER branch at :7838-7839, and that branch never names
    # a library at all: it only probes, and it ignores its own result. So
    # CONFIG_ICONV stays 1, nothing adds -liconv, and the build gets all the
    # way to the link before dying:
    #     Undefined symbols for architecture x86_64:
    #       "_iconv", referenced from: _avcodec_decode_subtitle2 in decode.o
    #       "_iconv_close", ...  "_iconv_open", ...
    #     ld: symbol(s) not found for architecture x86_64
    #     make: *** [libavcodec/libavcodec.62.dylib] Error 1
    # (macos-x86_64 in round 6 -- macos-arm64 had died at lzma before
    # reaching the link, but it takes exactly the same path.)
    #
    # test_ld appends $extralibs to every probe link line, so --extra-libs is
    # the lever here too, exactly as on Windows. Unlike Windows this needs no
    # libiconv of our own: /usr/lib/libiconv.2.dylib is a system library and
    # scripts/verify-output.sh's macOS allowlist already permits /usr/lib.
    TOOLCHAIN+=("--extra-libs=-liconv")
    TOOLCHAIN+=("--arch=$ARCH")
    TOOLCHAIN+=("--extra-cflags=-arch $ARCH")
    TOOLCHAIN+=("--extra-ldflags=-arch $ARCH")
    TOOLCHAIN+=("--install-name-dir=@rpath")
    TOOLCHAIN+=("--extra-ldflags=-Wl,-rpath,@loader_path/../lib")
    case "$ARCH" in
      arm64)  export MACOSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET_ARM64" ;;
      x86_64) export MACOSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET_X86_64" ;;
    esac
    # Cross-building x86_64 on an arm64 runner (or vice versa).
    if [ "$ARCH" != "$(detect_arch)" ]; then
      TOOLCHAIN+=("--enable-cross-compile")
      TOOLCHAIN+=("--target-os=darwin")
    fi
    ;;
esac

# --- feature flags ---------------------------------------------------------
declare -a FLAGS
# ARCH is passed so flags/ffmpeg.<os>.<arch>.flags applies. Only
# flags/ffmpeg.linux.arm64.flags exists today; it turns off libvpl, vaapi and
# amf, which have no aarch64 runtime.
while IFS= read -r f; do FLAGS+=("$f"); done < <(expand_flags "$OS" "$ARCH")
[ "${#FLAGS[@]}" -gt 0 ] || die "no flags expanded for $OS/$ARCH"

log "configure: $OS / $ARCH  (${#FLAGS[@]} feature flags)"
printf '  %s\n' "${FLAGS[@]}" >&2

# Record the exact command line beside the artefacts. This is part of the GPL
# corresponding-source obligation ("the scripts used to control compilation").
mkdir -p "$INSTALL/share/tas-ffmpeg"
{
  echo "# FFmpeg $FFMPEG_VERSION ($FFMPEG_TAG / $FFMPEG_COMMIT)"
  echo "# os=$OS arch=$ARCH"
  echo "./configure \\"
  printf '  %s \\\n' "${TOOLCHAIN[@]}" "${FLAGS[@]}"
  echo
} > "$INSTALL/share/tas-ffmpeg/configure-command.txt"

# *** ALWAYS SURFACE ffbuild/config.log WHEN configure FAILS. ***
#
# configure prints ONE line on failure and then tells you to look at a file
# that lives inside a container / a runner that is about to be destroyed:
#     ERROR: x265 not found using pkg-config
#     Include the log file "ffbuild/config.log" produced by configure ...
# That single line does not distinguish "the .pc is missing", "the .pc is
# malformed", "pkg-config is not on PATH" or "the probe COMPILED and then
# failed to LINK" -- four completely different bugs with four different
# fixes. Six CI rounds were spent inferring which one it was from that line,
# and the answer (a missing -lpthread on the probe link line) was sitting in
# config.log's last twenty lines the whole time, in every one of them.
#
# The tail is enough: config.log is append-only and configure dies on the
# first failing check, so the failing test's source, its exact command line
# and the compiler/linker output are always the last thing in the file.
if ! ( cd "$FF_BUILD" && "$FF_SRC/configure" "${TOOLCHAIN[@]}" "${FLAGS[@]}" ); then
  if [ -f "$FF_BUILD/ffbuild/config.log" ]; then
    printf '\n===== ffbuild/config.log (last 200 lines) =====\n' >&2
    tail -n 200 "$FF_BUILD/ffbuild/config.log" >&2
    printf '===== end of ffbuild/config.log =====\n\n' >&2
  else
    warn "configure failed before it wrote ffbuild/config.log"
  fi
  die "FFmpeg configure failed for $OS/$ARCH -- see the config.log tail above.
The last check in that log is the one that failed; look for the generated
test program and the command line under it, not just for the word ERROR."
fi

# Keep the generated config for provenance and so "why is encoder X missing?"
# is answerable without a rebuild.
cp "$FF_BUILD/ffbuild/config.log" "$INSTALL/share/tas-ffmpeg/config.log" 2>/dev/null || true
cp "$FF_BUILD/config.h"           "$INSTALL/share/tas-ffmpeg/config.h"   2>/dev/null || true

# --- VAAPI must not be dropped silently -------------------------------------
# configure SUCCEEDS with VAAPI disabled. --enable-vaapi is not in the
# autodetect-die list the way --enable-lzma is, so a failed libva probe is a
# warning at most, and the first symptom is verify-output.sh reporting
#     [VERIFY FAIL] config.h: HAVE_VAAPI_DRM is not 1
# forty minutes later, with no record of WHY the probe failed -- which is
# exactly how round 10 ended.
#
# QSV on Linux depends on this: the QSV hwcontext creates a VAAPI child device,
# so h264_qsv/hevc_qsv/vp9_qsv are listed as present and then fail at runtime
# with `-init_hw_device qsv`. TAS's matchEncoder() emits all three.
#
# So: fail HERE, where config.log is still at hand, and print the probes.
if [ "$OS" = linux ] && [ "$ARCH" = x86_64 ]; then
  _vaapi_ok=1
  grep -q '^#define CONFIG_VAAPI 1$'     "$FF_BUILD/config.h" || _vaapi_ok=0
  # HAVE_, not CONFIG_: `vaapi_drm` lives in configure's SYSTEM_LIBRARIES
  # (configure:2565-2571), which configure:2662 folds into HAVE_LIST. There is
  # no CONFIG_VAAPI_DRM in any FFmpeg build. `vaapi` itself IS a CONFIG_ item
  # (HWACCEL_AUTODETECT_LIBRARY_LIST -> CONFIG_LIST), hence the asymmetry.
  grep -q '^#define HAVE_VAAPI_DRM 1$' "$FF_BUILD/config.h" || _vaapi_ok=0
  if [ "$_vaapi_ok" -eq 0 ]; then
    printf '\n===== pkg-config state for the VAAPI stack =====\n' >&2
    printf 'PKG_CONFIG_PATH=%s\n' "${PKG_CONFIG_PATH:-<unset>}" >&2
    for _m in libva libva-drm libdrm; do
      if pkg-config --exists "$_m" 2>/dev/null; then
        printf '  %-10s FOUND    version=%s\n' "$_m" "$(pkg-config --modversion "$_m")" >&2
        printf '  %-10s   --libs          %s\n' '' "$(pkg-config --libs "$_m" 2>&1)" >&2
        printf '  %-10s   --static --libs %s\n' '' "$(pkg-config --static --libs "$_m" 2>&1)" >&2
      else
        printf '  %-10s NOT FOUND: %s\n' "$_m" "$(pkg-config --print-errors --exists "$_m" 2>&1 | head -3)" >&2
      fi
    done
    printf -- '--- installed .pc files ---\n' >&2
    ls -1 "$PREFIX_DIR"/lib/pkgconfig/ 2>&1 | sed 's/^/  /' >&2
    printf -- '--- vaapi probes from config.log ---\n' >&2
    grep -nE 'vaapi|va/va\.h|va/va_drm\.h|vaInitialize|vaGetDisplayDRM|-lva|-ldrm' \
      "$FF_BUILD/ffbuild/config.log" 2>/dev/null | tail -60 | sed 's/^/  /' >&2
    printf '===== end VAAPI diagnostics =====\n\n' >&2
    die "configure succeeded but VAAPI is NOT in the build (CONFIG_VAAPI / \
HAVE_VAAPI_DRM). h264_qsv, hevc_qsv and vp9_qsv would be listed as present
and then fail at runtime, because the QSV hwcontext needs a VAAPI child
device. See the diagnostics above: they show whether libva/libva-drm/libdrm
resolved through pkg-config and what configure's own probes did. Most likely
causes are build_libva's Implib.so stub not satisfying the vaInitialize link
test, or libva-drm.pc's dependency on our static libdrm not resolving."
  fi
  log "VAAPI is compiled in (CONFIG_VAAPI + HAVE_VAAPI_DRM)"
fi

make -C "$FF_BUILD" -j"$JOBS"
make -C "$FF_BUILD" install

# --- Linux: stamp the runpath AFTER install ---------------------------------
# Not via --extra-ldflags. See the long comment in the linux branch above: the
# literal string $ORIGIN cannot survive configure's append(), which evals its
# argument, and then make's `$$` -> `$`, and then /bin/sh. Two attempts each
# produced a DIFFERENT silently-wrong runpath (':/../lib' and a PID).
#
# patchelf writes the bytes into the ELF directly, so the only quoting that
# matters is this one pair of single quotes. TAS extracts our tarball and
# spawns bin/ffmpeg from it, and nelux loads lib/libav*.so from inside its
# wheel, so both consumers depend on a relocatable runpath -- neither sets
# LD_LIBRARY_PATH.
#
# Symlinks are skipped as an optimisation, not for correctness:
# libavcodec.so.62 points at libavcodec.so.62.28.102, so patching both just
# writes the same rpath to the same inode twice, and --set-rpath is
# idempotent. verify-output.sh reads through symlinks, so coverage is
# unaffected either way.
if [ "$OS" = linux ]; then
  command -v patchelf >/dev/null 2>&1 \
    || die "patchelf not found. It sets the \$ORIGIN runpath, without which
TAS's spawned bin/ffmpeg dies with 'error while loading shared libraries'.
It is normally present in the manylinux images (auditwheel depends on it);
docker/Dockerfile.manylinux_2_28 names it explicitly."
  # --- smoke test, either side of patchelf ---------------------------------
  # bin/ffmpeg SEGFAULTS on -version on this target while bin/ffprobe from the
  # same build runs fine. patchelf is a suspect precisely because it is the
  # only thing that touches the finished ELF, and it rewrites program headers
  # per binary -- so "same tool, one binary survives, the other does not" is
  # its known failure shape, not evidence against it.
  #
  # Before patchelf there is NO runpath at all, so the libraries have to come
  # from LD_LIBRARY_PATH; that is the only difference between the two runs
  # below. Pre-patch OK + post-patch segfault convicts patchelf. Both failing
  # acquits it and moves the search into FFmpeg or a static dependency.
  # NOTE the `if`: this script runs under `set -e`, and a bare command that
  # exits non-zero would take the build down before it could report anything.
  # A command in an `if` condition is exempt; a bare one is not.
  _smoke() {  # <when> <binary>
    if LD_LIBRARY_PATH="$INSTALL/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
         "$2" -hide_banner -version >/dev/null 2>&1; then
      _src=0
    else
      _src=$?
    fi
    if [ "$_src" -eq 0 ]; then
      log "smoke [$1] $(basename "$2") runs"
    else
      warn "smoke [$1] $(basename "$2") FAILED, exit $_src$([ "$_src" -gt 128 ] && printf ' (signal %s)' "$((_src - 128))")"
    fi
  }
  for _b in "$INSTALL/bin/ffmpeg" "$INSTALL/bin/ffprobe"; do
    [ -x "$_b" ] && _smoke pre-patchelf "$_b"
  done

  # The placeholder must be able to hold the real value, or patchelf goes back
  # to relocating PT_PHDR and we are back to a loader that segfaults. Assert it
  # here, where the fix is one string away, rather than discovering it as a
  # SIGSEGV forty minutes later.
  [ "${#RPATH_PLACEHOLDER}" -ge "${#RPATH_REAL}" ] || die \
"RPATH_PLACEHOLDER (${#RPATH_PLACEHOLDER} chars) is shorter than RPATH_REAL
(${#RPATH_REAL} chars). patchelf can only overwrite a runpath IN PLACE when the
new value fits in the old one; otherwise it rewrites the program headers, which
is what made bin/ffmpeg crash the dynamic loader. Lengthen the placeholder."

  _rpath_n=0
  _rpath_bad=""
  for _f in "$INSTALL"/lib/lib*.so.* "$INSTALL"/bin/ffmpeg "$INSTALL"/bin/ffprobe; do
    [ -f "$_f" ] || continue
    [ -L "$_f" ] && continue
    patchelf --set-rpath "$RPATH_REAL" "$_f"
    # Read the tag back. An object patchelf skipped would ship pointing at the
    # placeholder, which is a directory that does not exist.
    #
    # This MUST interrogate DT_RUNPATH, not grep the file: FFmpeg embeds the
    # entire configure command line in .rodata for avutil_configuration() /
    # `ffmpeg -buildconf`, so the placeholder string appears in every object
    # no matter what the runpath says. A grep-based version of this check
    # flagged all nine and cost a round.
    _got="$(patchelf --print-rpath "$_f" 2>/dev/null || true)"
    [ "$_got" = "$RPATH_REAL" ] || _rpath_bad="$_rpath_bad
  $(basename "$_f"): '$_got'"
    _rpath_n=$((_rpath_n + 1))
  done
  [ -z "$_rpath_bad" ] || die "patchelf did not record the expected runpath
('$RPATH_REAL') on:$_rpath_bad"
  log "set \$ORIGIN runpath on $_rpath_n ELF objects"

  for _b in "$INSTALL/bin/ffmpeg" "$INSTALL/bin/ffprobe"; do
    [ -x "$_b" ] && _smoke post-patchelf "$_b"
  done
fi

log "installed to $INSTALL"
"$REPO_ROOT/scripts/verify-output.sh" "$INSTALL"
"$REPO_ROOT/scripts/make-manifest.sh" "$INSTALL"
