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
    # Wrapping the value in SINGLE QUOTES fixes step 3: make still turns `$$`
    # into `$`, but sh then sees '$ORIGIN:$ORIGIN/../lib' inside single quotes
    # and performs no expansion, so ld receives the literal string.
    # scripts/verify-output.sh now ASSERTS that the built ELF's RUNPATH/RPATH
    # contains a literal `$ORIGIN`, because this class of bug is invisible to
    # every other check in this repo.
    TOOLCHAIN+=("--extra-ldflags=-Wl,-rpath,'\$\$ORIGIN:\$\$ORIGIN/../lib'")
    ;;
  macos)
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

( cd "$FF_BUILD" && "$FF_SRC/configure" "${TOOLCHAIN[@]}" "${FLAGS[@]}" )

# Keep the generated config for provenance and so "why is encoder X missing?"
# is answerable without a rebuild.
cp "$FF_BUILD/ffbuild/config.log" "$INSTALL/share/tas-ffmpeg/config.log" 2>/dev/null || true
cp "$FF_BUILD/config.h"           "$INSTALL/share/tas-ffmpeg/config.h"   2>/dev/null || true

make -C "$FF_BUILD" -j"$JOBS"
make -C "$FF_BUILD" install

log "installed to $INSTALL"
"$REPO_ROOT/scripts/verify-output.sh" "$INSTALL"
"$REPO_ROOT/scripts/make-manifest.sh" "$INSTALL"
