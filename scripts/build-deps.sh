#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/build-deps.sh
#
# Builds every external library as a STATIC lib into $PREFIX_DIR, and writes
# .pc files there. FFmpeg then finds them via PKG_CONFIG_PATH.
#
# Everything is static on purpose:
#   * nelux bundles only av*/sw* in its wheel. A dynamic libx264-164.dll or
#     zlib1.dll would be a missing-DLL crash at import time on every user
#     machine. scripts/verify-output.sh enforces this with an import
#     allowlist rather than trusting that we got it right.
#   * A static dep set keeps the Windows output to exactly the seven libav*
#     DLLs plus the two exes -- which is the layout
#     Theanimescripter/src/infra/getFFMPEG.py:316-335 already handles when it
#     flattens `bin/*` into `ffmpeg_shared/`.
#
# Per-target skips, each mirroring a flag in flags/ or an OS-provided library:
#   macOS         no libvpl, no AMF, no nv-codec-headers (no runtime exists)
#   linux/arm64   no libvpl, no AMF                      (no aarch64 runtime)
#   non-Linux     no gmp/nettle/GnuTLS  (Schannel / SecureTransport instead)
#   macOS         no bzip2              (bzlib.h is in the SDK, libbz2 in /usr/lib)
#                 xz IS built on macOS: the dylib is there but lzma.h is NOT
#                 in the SDK, so --enable-lzma cannot be satisfied from the
#                 system. See the block comment above build_xz.
#   non-Windows   no libiconv           (glibc and libSystem provide iconv)
#   linux/x86_64  ONLY libdrm + libva   (the VAAPI stack; --disable-vaapi on
#                 linux/arm64 and no libva on Windows/macOS). Both are built
#                 to be thrown away -- see the VAAPI block below.
# Everything else is built on all five targets: win64, linux64, linuxarm64,
# macos-arm64, macos-x86_64.
#
# THE SKIPS AND THE FLAG FILES MUST STAY IN STEP. libvpl is the sharp edge:
# configure:7309-7317 `die`s if --enable-libvpl is passed and vpl.pc is
# missing, so a skip here without the matching --disable-libvpl in
# flags/ffmpeg.<os>.<arch>.flags aborts the build outright.
# ---------------------------------------------------------------------------
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_lock

OS="$(detect_os)"
ARCH="${TARGET_ARCH:-$(detect_arch)}"
JOBS="$(nproc_portable)"

mkdir -p "$PREFIX_DIR" "$WORK_DIR"
export PKG_CONFIG_PATH="$PREFIX_DIR/lib/pkgconfig:$PREFIX_DIR/lib64/pkgconfig:${PKG_CONFIG_PATH:-}"
export CFLAGS="${CFLAGS:-} -fPIC -O2"
export CXXFLAGS="${CXXFLAGS:-} -fPIC -O2"

if [ "$OS" = "macos" ]; then
  case "$ARCH" in
    arm64)  export MACOSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET_ARM64" ;;
    x86_64) export MACOSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET_X86_64" ;;
  esac
  export CFLAGS="$CFLAGS -arch $ARCH"
  export CXXFLAGS="$CXXFLAGS -arch $ARCH"
fi

# ===========================================================================
# The C++ runtime, and how it reaches FFmpeg's link line
# ===========================================================================
# Several deps are C++ static libraries (x265, openh264, zimg, and libvmaf's
# C++ pieces). A static C++ archive cannot resolve its own operator new,
# __cxa_* and typeinfo references, so whatever links it must also name the C++
# runtime -- and FFmpeg links with $(CC), not $(CXX), so it is never implicit.
#
# FFmpeg gets it from pkg-config: scripts/build-ffmpeg.sh passes
# --pkg-config-flags=--static, so `pkg-config --static --libs x265` returns
# Libs + Libs.private, and Libs.private is where the C++ runtime belongs.
#
# *** WHY THIS IS NOT JUST "-lstdc++" ***
# Apple removed the libstdc++ stub in Xcode 10 (2018). On macOS the C++
# runtime is libc++, and ANY link line containing -lstdc++ fails outright:
#     ld: library 'stdc++' not found
# ffmpeg-8.1.2/configure:7432 checks x265 with `require_pkg_config`, which
# dies on failure -- so a single -lstdc++ anywhere in the .pc chain aborts
# BOTH macOS legs at configure time. x265's own CMake writes -lstdc++ into
# x265.pc's Libs.private on a static build, and build-deps.sh used to sed a
# SECOND one into Libs on top of that.
#
# Note the ordering trap that hid this: configure checks libopenh264 at :7343
# and libvmaf at :7391, both BEFORE libx265 at :7432. Any of the three can
# abort the build; today they merely happen to be checked in an order where
# x265 fails first.
#
# *** WHY WINDOWS IS NOT "-lstdc++" EITHER ***
# MSYS2 ships BOTH libstdc++.a and libstdc++.dll.a, and GNU ld prefers the
# .dll.a. A plain -lstdc++ therefore makes avcodec-62.dll import
# libstdc++-6.dll (and, transitively, libwinpthread-1.dll) -- neither of which
# nelux's wheel ships. `-l:libstdc++.a` names the archive exactly, which is
# the only spelling GNU ld treats as "this file, not the import library".
# (gcc's own -static-libstdc++ does NOT help here: it only rewrites the
# IMPLICIT -lstdc++ that the g++ driver adds, and FFmpeg links with gcc and an
# EXPLICIT -lstdc++ from pkg-config.)
cxx_runtime_lib() {
  case "$OS" in
    macos)   echo "-lc++" ;;
    windows) echo "-l:libstdc++.a" ;;
    *)       echo "-lstdc++" ;;
  esac
}

# pc_fix_cxx <path/to/foo.pc>
# Rewrites every -lstdc++ in a generated .pc to this platform's C++ runtime,
# and guarantees the runtime appears in Libs.private if the project did not
# emit one at all (meson's pkgconfig module does not add it for static C++
# libraries, so openh264.pc arrives without it on every platform).
# Idempotent, and a HARD FAILURE if the .pc is missing.
#
# It used to warn and continue, on the theory that a missing .pc is "already
# fatal at FFmpeg's require_pkg_config with a clearer message". Both halves of
# that were wrong, and it cost a full CI round to find out. When x265 silently
# stopped installing x265.pc, the Linux legs printed
#     [warn] expected /work/build/deps/lib/pkgconfig/x265.pc after install ...
# and then built openh264, dav1d, SVT-AV1, libaom, libvpx, opus, zimg, libvmaf
# and GnuTLS for another NINE MINUTES before dying ~9000 log lines later with
#     ERROR: x265 not found using pkg-config
# which names neither the file nor the build step that should have produced
# it. Every .pc passed to this function is checked by a `require_pkg_config`
# in configure -- libx265 at :7432, libopenh264 at :7343, libvmaf at :7391,
# libzimg at :7441 -- and every one of those libraries is enabled
# unconditionally in flags/ffmpeg.flags on all five targets. So there is no
# case where a missing one of these is survivable; failing here is strictly
# better information, delivered ~10 minutes earlier.
pc_fix_cxx() {
  local pc="$1" cxx
  cxx="$(cxx_runtime_lib)"
  if [ ! -f "$pc" ]; then
    die "$(basename "$pc") was not installed into $(dirname "$pc").
The library built and installed, but its pkg-config file is missing, so
FFmpeg's require_pkg_config for it will fail. Look at what the dependency's
own build system makes that file CONDITIONAL on -- x265, for one, only emits
x265.pc when it can determine a version (x265/source/CMakeLists.txt:1113,
which needs a tag reachable from HEAD; see restore_pin_tag in
scripts/lib/common.sh)."
  fi
  sed -i.bak -e "s|-lstdc++|$cxx|g" "$pc"
  rm -f "$pc.bak"
  if ! grep -qF -- "$cxx" "$pc"; then
    if grep -q '^Libs\.private:' "$pc"; then
      sed -i.bak -e "s|^Libs\.private:.*|& $cxx|" "$pc"
      rm -f "$pc.bak"
    else
      printf 'Libs.private: %s\n' "$cxx" >> "$pc"
    fi
  fi
  log "  $(basename "$pc"): C++ runtime is $cxx"
}

# stamp NAME -- skip a dep that is already built for this exact commit.
stamp()      { echo "$PREFIX_DIR/.stamp-$1"; }
have_stamp() { [ -f "$(stamp "$1")" ] && [ "$(cat "$(stamp "$1")")" = "$2" ]; }
set_stamp()  { mkdir -p "$PREFIX_DIR"; echo "$2" > "$(stamp "$1")"; }

# ===========================================================================
# zlib -- static, from source. See versions.lock ZLIB_* for why this is not
# taken from the system.
# ===========================================================================
build_zlib() {
  have_stamp zlib "$ZLIB_COMMIT" && { log "zlib up to date"; return; }
  log "building zlib $ZLIB_TAG"
  rm -rf "$WORK_DIR/zlib"; cp -r "$SRC_DIR/zlib" "$WORK_DIR/zlib"
  ( cd "$WORK_DIR/zlib"
    if [ "$OS" = "windows" ]; then
      # zlib's configure does not understand mingw; use its win32 makefile.
      make -f win32/Makefile.gcc -j"$JOBS" libz.a
      mkdir -p "$PREFIX_DIR/lib/pkgconfig" "$PREFIX_DIR/include"
      cp libz.a "$PREFIX_DIR/lib/"
      cp zlib.h zconf.h "$PREFIX_DIR/include/"
      sed -e "s|@prefix@|$PREFIX_DIR|g" -e "s|@exec_prefix@|$PREFIX_DIR|g" \
          -e "s|@libdir@|$PREFIX_DIR/lib|g" -e "s|@sharedlibdir@|$PREFIX_DIR/lib|g" \
          -e "s|@includedir@|$PREFIX_DIR/include|g" -e "s|@VERSION@|${ZLIB_TAG#v}|g" \
          zlib.pc.in > "$PREFIX_DIR/lib/pkgconfig/zlib.pc"
    else
      ./configure --prefix="$PREFIX_DIR" --static
      make -j"$JOBS" && make install
    fi
  )
  set_stamp zlib "$ZLIB_COMMIT"
}

# ===========================================================================
# bzip2 / xz(liblzma) / libiconv -- WINDOWS + LINUX, static, from source
#
# flags/ffmpeg.flags:181-186 asks for --enable-bzlib, --enable-lzma and
# --enable-iconv on every platform, and until now NOTHING built them: they
# were silently satisfied from MSYS2 (Windows) and from the manylinux image's
# bzip2-devel / xz-devel (Linux). Both of those ship the SHARED library, GNU
# ld prefers it, and the result is avcodec-62.dll importing libbz2-1.dll /
# liblzma-5.dll / libiconv-2.dll, or libavformat.so.62 carrying DT_NEEDED
# libbz2.so.1 / liblzma.so.5. Neither consumer ships any of those, so it is an
# ImportError on a user's machine and an auditwheel rejection for nelux's
# manylinux_2_28 wheel. Same reasoning as zlib above; see versions.lock.
#
# macOS is excluded for bzlib and iconv ONLY: bzlib.h and iconv.h are in the
# SDK and libbz2/libiconv are in /usr/lib, which verify-output.sh's macOS
# allowlist already permits, on the same footing as SecureTransport and
# VideoToolbox.
#
# *** liblzma IS NOT IN THAT CATEGORY, AND ASSUMING IT WAS COST A CI ROUND. ***
# macOS ships /usr/lib/liblzma.5.dylib for its own tools but publishes NO
# lzma.h in the SDK, so configure:7188
#     enabled lzma && check_lib lzma lzma.h lzma_version_number -llzma
# cannot even compile its probe. lzma is in EXTERNAL_AUTODETECT_LIBRARY_LIST
# (configure:1977) and flags/ffmpeg.flags:182 REQUESTS it, so the generic
# guard at configure:8286-8287
#     requested $lib && ! enabled $lib && die "ERROR: $lib requested but not found"
# turns that into a hard abort AFTER every dependency has been built:
#     ERROR: lzma requested but not found
# Note bzlib is checked first in that same loop (:7187, and it sits above
# lzma in the list) and passed, which is what proves the header -- not the
# dylib -- is what macOS is missing.
#
# These install ONLY a .a and a header into $PREFIX_DIR, which
# scripts/build-ffmpeg.sh puts ahead of the toolchain's own directories with
# `--extra-ldflags=-L$PREFIX_DIR/lib`. Since our directory contains no .dll.a
# / .so, `-lbz2`, `-llzma` and `-liconv` cannot resolve to a shared library.
# ===========================================================================
need_compression_libs() { [ "$OS" != "macos" ]; }

build_bzip2() {
  need_compression_libs || { log "skipping bzip2 (macOS SDK provides bzlib.h + /usr/lib/libbz2)"; return; }
  have_stamp bzip2 "$BZIP2_VERSION" && { log "bzip2 up to date"; return; }
  log "building bzip2 $BZIP2_VERSION (static)"
  rm -rf "$WORK_DIR/bzip2"; mkdir -p "$WORK_DIR/bzip2"
  tar -C "$WORK_DIR/bzip2" --strip-components=1 -xf "$SRC_DIR/$(dep_tarball BZIP2)"
  # *** -DBZ_EXPORT ON WINDOWS IS MANDATORY, NOT COSMETIC ***
  # bzlib.h:78-95 -- on _WIN32 WITHOUT BZ_EXPORT the header declares every
  # entry point as a function POINTER (`#define BZ_API(func) (WINAPI * func)`
  # with an empty BZ_EXTERN), so `BZ2_bzlibVersion` becomes a tentative
  # definition of a NULL pointer. That still compiles and links, so FFmpeg's
  # `check_lib bzlib bzlib.h BZ2_bzlibVersion -lbz2` PASSES and matroska
  # bzlib decompression then calls a null pointer at runtime. Distro packages
  # patch this header; we build vanilla source, so we define BZ_EXPORT both
  # here and in the FFmpeg CFLAGS (scripts/build-ffmpeg.sh). WINAPI is
  # __stdcall, a no-op on x86-64, so the ABI does not change.
  local bzdefs=""
  [ "$OS" = "windows" ] && bzdefs="-DBZ_EXPORT"
  ( cd "$WORK_DIR/bzip2"
    # bzip2's Makefile hardcodes CFLAGS, so it must be overridden on the
    # command line (which also drops -g and the test/CLI targets we do not
    # want). -D_FILE_OFFSET_BITS=64 is bzip2's own BIGFILES setting.
    make libbz2.a -j"$JOBS" \
      CC="${CC:-gcc}" \
      CFLAGS="$CFLAGS -D_FILE_OFFSET_BITS=64 $bzdefs"
    mkdir -p "$PREFIX_DIR/lib" "$PREFIX_DIR/include"
    cp libbz2.a "$PREFIX_DIR/lib/"
    cp bzlib.h  "$PREFIX_DIR/include/" )
  set_stamp bzip2 "$BZIP2_VERSION"
}

# NOT guarded by need_compression_libs -- built on ALL THREE OSes. See the
# block comment above: macOS has the dylib but no lzma.h, so it needs this
# just as much as Windows and Linux do, only for a different reason.
build_xz() {
  have_stamp xz "$XZ_VERSION" && { log "liblzma up to date"; return; }
  log "building xz/liblzma $XZ_VERSION (static)"
  rm -rf "$WORK_DIR/xz"; mkdir -p "$WORK_DIR/xz"
  tar -C "$WORK_DIR/xz" --strip-components=1 -xf "$SRC_DIR/$(dep_tarball XZ)"
  ( cd "$WORK_DIR/xz"
    # Only liblzma is wanted; every CLI tool and script is off. --disable-nls
    # keeps gettext out of the picture. --disable-threads is deliberate: the
    # only liblzma entry points FFmpeg uses are the single-threaded ones
    # (lzma_stream_buffer_decode / lzma_alone_decoder), and disabling threads
    # guarantees the static archive cannot pull in libwinpthread on MinGW.
    ./configure --prefix="$PREFIX_DIR" \
                --enable-static --disable-shared --with-pic \
                --disable-threads --disable-nls --disable-doc \
                --disable-xz --disable-xzdec --disable-lzmadec \
                --disable-lzmainfo --disable-lzma-links --disable-scripts
    make -j"$JOBS" && make install )
  set_stamp xz "$XZ_VERSION"
}

build_libiconv() {
  [ "$OS" = "windows" ] || { log "skipping libiconv ($OS provides iconv in libc)"; return; }
  have_stamp libiconv "$LIBICONV_VERSION" && { log "libiconv up to date"; return; }
  log "building GNU libiconv $LIBICONV_VERSION (static)"
  rm -rf "$WORK_DIR/libiconv"; mkdir -p "$WORK_DIR/libiconv"
  tar -C "$WORK_DIR/libiconv" --strip-components=1 -xf "$SRC_DIR/$(dep_tarball LIBICONV)"
  ( cd "$WORK_DIR/libiconv"
    ./configure --prefix="$PREFIX_DIR" \
                --enable-static --disable-shared --with-pic --disable-nls
    make -j"$JOBS" && make install )
  # Only the library ever leaves $PREFIX_DIR (which is a build sysroot, never
  # packaged). The `iconv` COMMAND is GPL while the library is LGPL-2.1; we
  # neither link nor ship the command.
  set_stamp libiconv "$LIBICONV_VERSION"
}

# ===========================================================================
# nv-codec-headers -- headers + ffnvcodec.pc only, no code.
# ===========================================================================
build_nvcodec() {
  [ "$OS" = "macos" ] && { log "skipping nv-codec-headers (no CUDA on macOS)"; return; }
  have_stamp nvcodec "$NVCODEC_COMMIT" && { log "nv-codec-headers up to date"; return; }
  log "installing nv-codec-headers $NVCODEC_TAG (driver floor: Linux >= $NVCODEC_DRIVER_MIN_LINUX / Windows >= $NVCODEC_DRIVER_MIN_WINDOWS)"
  make -C "$SRC_DIR/nv-codec-headers" PREFIX="$PREFIX_DIR" install
  set_stamp nvcodec "$NVCODEC_COMMIT"
}

# ===========================================================================
# AMF -- header-only. FFmpeg wants <AMF/core/...> on the include path.
# ===========================================================================
build_amf() {
  [ "$OS" = "macos" ] && { log "skipping AMF (no macOS runtime)"; return; }
  # linux/aarch64: amdgpu-pro and the Mesa AMF bridge are x86_64-only, so
  # flags/ffmpeg.linux.arm64.flags passes --disable-amf and the headers would
  # be dead weight in the include tree.
  [ "$OS" = "linux" ] && [ "$ARCH" = "arm64" ] && { log "skipping AMF (no aarch64 runtime)"; return; }
  have_stamp amf "$AMF_COMMIT" && { log "AMF headers up to date"; return; }
  log "installing AMF headers $AMF_TAG"
  mkdir -p "$PREFIX_DIR/include/AMF"
  cp -r "$SRC_DIR/AMF/amf/public/include/." "$PREFIX_DIR/include/AMF/"
  set_stamp amf "$AMF_COMMIT"
}

# ===========================================================================
# libvpl -- the oneVPL DISPATCHER only. Provides vpl.pc, which
# ffmpeg configure:7309-7317 requires (>= 2.6) with NO fallback.
# ===========================================================================
build_libvpl() {
  [ "$OS" = "macos" ] && { log "skipping libvpl (no oneVPL runtime on macOS)"; return; }
  # linux/aarch64: no Intel GPU, no aarch64 oneVPL runtime. This skip MUST
  # stay in step with the --disable-libvpl in flags/ffmpeg.linux.arm64.flags:
  # configure:7309-7317 `die`s outright if libvpl is enabled and vpl.pc is
  # absent, so building the dispatcher without the flag (or vice versa) is a
  # hard configure failure rather than a degraded build.
  [ "$OS" = "linux" ] && [ "$ARCH" = "arm64" ] && { log "skipping libvpl (no aarch64 oneVPL runtime)"; return; }
  have_stamp libvpl "$LIBVPL_COMMIT" && { log "libvpl up to date"; return; }
  log "building libvpl $LIBVPL_TAG (dispatcher)"
  rm -rf "$WORK_DIR/libvpl"
  cmake -S "$SRC_DIR/libvpl" -B "$WORK_DIR/libvpl" -G Ninja \
    -DCMAKE_INSTALL_PREFIX="$PREFIX_DIR" -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTS=OFF -DBUILD_EXAMPLES=OFF \
    -DBUILD_TOOLS=OFF -DINSTALL_EXAMPLE_CODE=OFF
  cmake --build "$WORK_DIR/libvpl" -j "$JOBS"
  cmake --install "$WORK_DIR/libvpl"
  set_stamp libvpl "$LIBVPL_COMMIT"
}

# ===========================================================================
# VAAPI -- linux/x86_64 only, and linked through Implib.so STUBS.
#
# Read versions.lock's VAAPI block first; it carries the whole argument. The
# one-line version: QSV on Linux needs --enable-vaapi (the QSV hwcontext
# creates a VAAPI child device), linking libva normally puts DT_NEEDED
# libva.so.2 / libva-drm.so.2 / libdrm.so.2 into libavutil.so.60, and all
# three are outside the manylinux_2_28 policy set that nelux's wheel must
# satisfy. verify-output.sh asserts their ABSENCE, positively, after every
# Linux build.
# ===========================================================================

# vaapi_target -- true only where flags/ffmpeg.linux.flags asks for VAAPI.
# flags/ffmpeg.linux.arm64.flags:41 passes --disable-vaapi (no aarch64 QSV
# runtime), and Windows/macOS use libva not at all, so building any of this
# there would be dead weight that still had to be verified and licensed.
vaapi_target() { [ "$OS" = "linux" ] && [ "$ARCH" = "x86_64" ]; }

# implib_python -- the interpreter that runs implib-gen.py.
#
# NOT plain `python3`: on AlmaLinux 8 (the manylinux_2_28 base) /usr/bin/
# python3 is 3.6, and implib-gen.py is written against a modern Python.
# The manylinux images ship their own CPythons under /opt/python, and
# docker/Dockerfile.manylinux_2_28 already pins meson and ninja to the
# cp312 one -- use the same interpreter so there is a single Python in play.
implib_python() {
  local p
  for p in /opt/python/cp312-cp312/bin/python3 python3; do
    command -v "$p" >/dev/null 2>&1 || continue
    # 3.8 is the floor implib-gen.py is realistically tested against; the
    # 3.6 in EL8's /usr/bin is what this rejects.
    "$p" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' 2>/dev/null \
      && { printf '%s' "$p"; return 0; }
  done
  die "no Python >= 3.8 found to run Implib.so's implib-gen.py.
The VAAPI stub generator needs one (see versions.lock IMPLIB_*). Inside
docker/Dockerfile.manylinux_2_28 this is /opt/python/cp312-cp312/bin/python3."
}

# gen_implib <input.so> <output.a>
# ADAPTED FROM BtbN/FFmpeg-Builds images/base-linux64/gen-implib.sh (MIT).
#
# Turns a real shared library into a STATIC ARCHIVE of trampolines. Each
# exported function becomes a stub that, on ITS FIRST CALL, dlopen()s the
# library by its SONAME and dlsym()s the real symbol. Link that archive
# instead of the .so and the result has NO DT_NEEDED for it: the loader never
# sees the dependency, so a machine without libva loads our libraries fine and
# only pays if it actually asks for QSV.
#
# CHANGED vs upstream: no ${FFBUILD_CROSS_PREFIX} (this is a native build, not
# a crosstool-NG cross-compile) and the interpreter is resolved by
# implib_python above rather than assumed to be /usr/bin/python3.
#
# *** THE ONE BEHAVIOURAL COST, STATED PLAINLY ***
# Implib.so's generated loader (arch/common/init.c.tpl) does
#     CHECK(lib_handle, "failed to load library '%s' via dlopen: %s", ...)
# and CHECK is fprintf + assert(0) + abort(). So on a machine with NO libva at
# all, asking for QSV aborts the process instead of returning an AVERROR.
# That is still strictly better than today: with a real DT_NEEDED the same
# machine cannot load libavutil.so.60 AT ALL -- nelux fails at `import nelux`
# and TAS fails at `ffmpeg -version`, for every user, whether or not they ever
# touch QSV. --lazy-load is what confines the cost to the QSV path.
gen_implib() {
  local in="$1" out="$2" tmp py cc
  [ -f "$in" ] || die "gen_implib: $in does not exist.
The stub is generated FROM the real shared object, so this means libva did
not install what we expected -- most likely its SONAME moved. Check
libva/meson.build's soversion (libva_lt_current) against what build_libva
asks for; a SONAME bump also changes the name the stub dlopen()s at runtime,
which is not a thing to paper over with a glob."
  py="$(implib_python)"
  cc="${CC:-gcc}"
  command -v readelf >/dev/null 2>&1 \
    || die "gen_implib needs readelf (implib-gen.py shells out to it to read the
dynamic symbol table). Install binutils."
  tmp="$(mktemp -d)"
  ( cd "$tmp"
    "$py" "$SRC_DIR/Implib.so/implib-gen.py" \
      --target x86_64-linux-gnu --dlopen --lazy-load --verbose "$in"
    # -Wa,--noexecstack: the trampolines are hand-written assembly, and a .S
    # without an explicit .note.GNU-stack marks the stack EXECUTABLE for the
    # whole of libavutil.so. -DIMPLIB_HIDDEN_SHIMS keeps the va* symbols
    # hidden so linking the stub does not make libavutil re-export the VA ABI.
    # shellcheck disable=SC2086  # CFLAGS must word-split
    $cc $CFLAGS -Wa,--noexecstack -DIMPLIB_HIDDEN_SHIMS -c ./*.tramp.S ./*.init.c
    ar -rcs "$out" ./*.tramp.o ./*.init.o )
  rm -rf "$tmp"
  [ -f "$out" ] || die "gen_implib produced no archive at $out"
  log "  stub archive: $(basename "$out") (dlopens $(basename "$in") lazily)"
}

# pc_add_ldl <path/to/foo.pc>
# The stub archive calls dlopen/dlsym, so whatever links it needs -ldl. On
# glibc 2.28 that is a real separate library, not a no-op stub as it is on
# glibc >= 2.34, and libdl.so.2 IS inside the manylinux_2_28 policy set.
#
# BtbN append a second `Libs:` line with `>>`. That works under pkgconf, which
# accumulates duplicate keys, and is silently DROPPED by freedesktop
# pkg-config 0.29, which reports "Libs field occurs twice" and returns the
# first. The image installs pkgconf today, but the failure mode of getting
# this wrong is a link error 15 minutes later that names neither file, so
# extend the EXISTING line instead of relying on which implementation is on
# PATH.
pc_add_ldl() {
  local pc="$1"
  [ -f "$pc" ] || die "$(basename "$pc") was not installed into $(dirname "$pc").
ffmpeg-8.1.2/configure:7667-7676 finds both libva and libva-drm through
pkg-config and there is no fallback; a missing .pc here means vaapi silently
fails to configure, and configure:8285-8287 then hard-dies because
--enable-vaapi was requested."
  grep -q '^Libs:' "$pc" || die "$(basename "$pc") has no Libs: line to extend"
  grep -q -- '-ldl' "$pc" && return 0   # idempotent
  sed -i.bak -e 's|^Libs:.*|& -ldl|' "$pc"
  rm -f "$pc.bak"
}

# ---------------------------------------------------------------------------
# libdrm -- STATIC, and only because libva refuses to build without it.
#
# libva/meson.build:88 does dependency('libdrm', '>= 2.4.75', required: true)
# on every non-Windows host, and libva-drm.pc then carries it onto FFmpeg's
# link line because scripts/build-ffmpeg.sh passes --pkg-config-flags=--static.
# We do NOT pass --enable-libdrm, so no FFmpeg object references a drm* symbol
# and the linker extracts ZERO members from this archive -- it exists purely so
# `-ldrm` resolves to something that is not the system libdrm.so.2.
#
# Every per-GPU KMS helper is off. BtbN enable -Dintel/nouveau/radeon/amdgpu
# and consequently have to build libpciaccess as well; libdrm_intel and
# friends are separate libraries that nothing here links, so that whole recipe
# is not ported.
# ---------------------------------------------------------------------------
build_libdrm() {
  vaapi_target || { log "skipping libdrm (VAAPI stack is linux/x86_64 only)"; return; }
  have_stamp libdrm "$LIBDRM_COMMIT" && { log "libdrm up to date"; return; }
  log "building libdrm $LIBDRM_TAG (static, prerequisite of libva)"
  rm -rf "$WORK_DIR/libdrm"
  meson setup "$WORK_DIR/libdrm" "$SRC_DIR/libdrm" \
    --prefix="$PREFIX_DIR" --libdir=lib --buildtype=release \
    --default-library=static \
    -Dtests=false -Dinstall-test-programs=false -Dudev=false \
    -Dcairo-tests=disabled -Dvalgrind=disabled -Dman-pages=disabled \
    -Dintel=disabled -Dradeon=disabled -Damdgpu=disabled -Dnouveau=disabled \
    -Dvmwgfx=disabled -Dfreedreno=disabled -Dvc4=disabled -Detnaviv=disabled \
    -Domap=disabled -Dexynos=disabled -Dtegra=disabled
  ninja -C "$WORK_DIR/libdrm" -j "$JOBS"
  ninja -C "$WORK_DIR/libdrm" install
  [ -f "$PREFIX_DIR/lib/pkgconfig/libdrm.pc" ] \
    || die "libdrm installed no libdrm.pc; libva's dependency('libdrm') will not resolve"
  [ -f "$PREFIX_DIR/lib/libdrm.a" ] \
    || die "libdrm installed no static libdrm.a. --default-library=static was
ignored, which means -ldrm on FFmpeg's link line would resolve against the
SYSTEM libdrm.so.2 and put a DT_NEEDED outside the manylinux_2_28 policy set
into libavutil.so.$SONAME_AVUTIL."
  set_stamp libdrm "$LIBDRM_COMMIT"
}

# ---------------------------------------------------------------------------
# libva -- built SHARED, then replaced by Implib.so stub archives and deleted.
#
# The .so we build is a means to an end: it is what the stub generator reads
# the exported symbol table out of, and it is what fixes the name the stubs
# dlopen at runtime (its SONAME, libva.so.2). It is never shipped and never
# loaded -- the library that actually runs is the USER's libva.so.2, which is
# the point: it is the copy that knows that machine's driver directory, reads
# its /etc/libva.conf and matches its installed VA driver. Statically linking
# our own libva would make US responsible for finding the user's
# iHD_drv_video.so, from a driverdir baked in at build time that is different
# on Debian, Fedora and Arch.
#
# X11, GLX and Wayland are all off. VAAPI exists here only to give the QSV
# hwcontext a child device; that path is libva + libva-drm and never touches a
# display. Neither consumer creates AV_HWDEVICE_TYPE_VAAPI directly, and both
# run headless (nelux inside a Python process, TAS spawning a CLI). Leaving
# them on would pull the whole X11 dependency tree in for nothing.
# ---------------------------------------------------------------------------
build_libva() {
  vaapi_target || { log "skipping libva (VAAPI stack is linux/x86_64 only)"; return; }
  # The stamp covers the stub generator too: a new Implib.so commit changes
  # the emitted trampolines, which are compiled into what we ship.
  have_stamp libva "$LIBVA_COMMIT-$IMPLIB_COMMIT" && { log "libva up to date"; return; }
  log "building libva $LIBVA_TAG (shared, then stubbed with Implib.so $IMPLIB_TAG)"
  rm -rf "$WORK_DIR/libva"
  meson setup "$WORK_DIR/libva" "$SRC_DIR/libva" \
    --prefix="$PREFIX_DIR" --libdir=lib --buildtype=release \
    --default-library=shared \
    -Denable_docs=false -Ddisable_drm=false \
    -Dwith_x11=no -Dwith_glx=no -Dwith_wayland=no -Dwith_win32=no
  ninja -C "$WORK_DIR/libva" -j "$JOBS"
  ninja -C "$WORK_DIR/libva" install

  # libva/meson.build:59-63 computes soversion from the VA-API version:
  # VA-API 1.24.0 -> libva.so.2 / libva.so.2.2400.0. Asserted rather than
  # globbed because the SONAME is ALSO the string the stubs dlopen at runtime;
  # if upstream ever moves to libva.so.3 we would silently start emitting
  # binaries that dlopen a library no distribution ships yet.
  gen_implib "$PREFIX_DIR/lib/libva.so.2"     "$PREFIX_DIR/lib/libva.a"
  gen_implib "$PREFIX_DIR/lib/libva-drm.so.2" "$PREFIX_DIR/lib/libva-drm.a"

  # DELETE the shared objects. Not tidiness: while libva.so is present in
  # $PREFIX_DIR/lib, `-lva` resolves to it in preference to libva.a (GNU ld
  # prefers the shared library when both are on the same -L path) and we would
  # ship the DT_NEEDED after all -- the exact failure this whole recipe
  # exists to prevent, silently, with a green build.
  rm -f "$PREFIX_DIR"/lib/libva.so* "$PREFIX_DIR"/lib/libva-drm.so*
  ls "$PREFIX_DIR"/lib/libva*.so* >/dev/null 2>&1 \
    && die "libva shared objects still present in $PREFIX_DIR/lib after the stub
generation -- -lva would resolve to the .so and libavutil would acquire
DT_NEEDED libva.so.2."

  pc_add_ldl "$PREFIX_DIR/lib/pkgconfig/libva.pc"
  pc_add_ldl "$PREFIX_DIR/lib/pkgconfig/libva-drm.pc"
  set_stamp libva "$LIBVA_COMMIT-$IMPLIB_COMMIT"
}

# ===========================================================================
# x264 -- GPL. Static, no CLI.
# ===========================================================================
build_x264() {
  have_stamp x264 "$X264_COMMIT" && { log "x264 up to date"; return; }
  log "building x264 $X264_TAG"
  rm -rf "$WORK_DIR/x264"; cp -r "$SRC_DIR/x264" "$WORK_DIR/x264"
  local extra=""
  [ "$OS" = "macos" ] && extra="--host=$ARCH-apple-darwin"
  ( cd "$WORK_DIR/x264"
    ./configure --prefix="$PREFIX_DIR" --enable-static --enable-pic \
                --disable-cli --disable-opencl $extra
    make -j"$JOBS" && make install )
  set_stamp x264 "$X264_COMMIT"
}

# ===========================================================================
# x265 -- GPL, and the single largest contributor to binary size.
#
# We build the full MULTILIB (8-bit + 10-bit + 12-bit) because both consumers
# need >8-bit: TAS has x265_10bit and hevc_nvenc_10bit presets
# (encodingSettings.py:109-123, :159-171) and nelux's tests cover 10-bit
# pixel formats. The cost is ~22.7 MB on Windows -- see README.md#size.
# Dropping to 8-bit only would save roughly 15 MB and break -profile:v main10.
#
# The 10/12-bit builds are compiled with EXPORT_C_API=OFF so their symbols are
# namespaced (x265_10bit_*, x265_12bit_*), then linked into the 8-bit lib.
#
# *** THIS BUILD DEPENDS ON THE x265 CHECKOUT HAVING A TAG. ***
# x265's Version.cmake:144-151 gets X265_LATEST_TAG from `git describe
# --abbrev=0 --tags`, and TWO things downstream break when that comes back
# empty: CMakeLists.txt:1041-1043 aborts configure outright wherever a
# resource compiler exists (i.e. MinGW/Windows), and CMakeLists.txt:1113
# silently skips generating and installing x265.pc everywhere, which then
# kills FFmpeg's configure:7432 require_pkg_config. A `git init` + `fetch
# --depth 1 <sha>` checkout has no tags at all, so scripts/lib/common.sh's
# restore_pin_tag puts X265_TAG back as a local tag. Read its comment before
# changing anything about how sources are fetched.
# ===========================================================================
build_x265() {
  have_stamp x265 "$X265_COMMIT" && { log "x265 up to date"; return; }
  log "building x265 $X265_TAG (multilib 8/10/12-bit)"
  local S="$SRC_DIR/x265/source" B="$WORK_DIR/x265"
  rm -rf "$B"; mkdir -p "$B/8" "$B/10" "$B/12"
  local common="-DCMAKE_BUILD_TYPE=Release -DENABLE_SHARED=OFF -DENABLE_CLI=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON"
  # 12-bit
  cmake -S "$S" -B "$B/12" -G Ninja $common -DHIGH_BIT_DEPTH=ON -DMAIN12=ON -DEXPORT_C_API=OFF
  cmake --build "$B/12" -j "$JOBS"
  # 10-bit
  cmake -S "$S" -B "$B/10" -G Ninja $common -DHIGH_BIT_DEPTH=ON -DEXPORT_C_API=OFF
  cmake --build "$B/10" -j "$JOBS"
  # 8-bit, linked against the other two
  cp "$B/10/libx265.a" "$B/8/libx265_main10.a"
  cp "$B/12/libx265.a" "$B/8/libx265_main12.a"
  cmake -S "$S" -B "$B/8" -G Ninja $common \
    -DCMAKE_INSTALL_PREFIX="$PREFIX_DIR" \
    -DEXTRA_LIB="x265_main10.a;x265_main12.a" -DEXTRA_LINK_FLAGS=-L. \
    -DLINKED_10BIT=ON -DLINKED_12BIT=ON
  cmake --build "$B/8" -j "$JOBS"
  # Merge the three static archives into one libx265.a.
  ( cd "$B/8"
    mv libx265.a libx265_main.a
    if [ "$OS" = "macos" ]; then
      # APPLE's libtool (an archive tool), NOT GNU libtool (a build script).
      # Spelled absolutely because the macOS CI leg now installs Homebrew's
      # `libtool` for zimg's autoreconf, and while Homebrew keeps the GNU one
      # out of the way as `glibtoolize`/`glibtool`, this call must not be at
      # the mercy of PATH order -- GNU libtool here would silently produce
      # nothing resembling a static archive.
      /usr/bin/libtool -static -o libx265.a libx265_main.a libx265_main10.a libx265_main12.a
    else
      printf 'CREATE libx265.a\nADDLIB libx265_main.a\nADDLIB libx265_main10.a\nADDLIB libx265_main12.a\nSAVE\nEND\n' | ar -M
    fi )
  cmake --install "$B/8"
  cp "$B/8/libx265.a" "$PREFIX_DIR/lib/libx265.a"
  # x265's CMake writes `-lstdc++` into x265.pc's Libs.private for a static
  # build. That is correct on Linux, fatal on macOS (Xcode 10 removed the
  # libstdc++ stub, so ld dies with "library 'stdc++' not found" and
  # configure:7432's require_pkg_config turns that into a hard abort), and
  # wrong on Windows (GNU ld resolves -lstdc++ to libstdc++.dll.a and the DLLs
  # grow an import on libstdc++-6.dll). pc_fix_cxx rewrites it to whatever
  # this platform's C++ runtime actually is.
  pc_fix_cxx "$PREFIX_DIR/lib/pkgconfig/x265.pc"
  set_stamp x265 "$X265_COMMIT"
}

# ===========================================================================
# dav1d -- AV1 decoder. FIRST in nelux's AV1 decoder preference chain.
# ===========================================================================
build_dav1d() {
  have_stamp dav1d "$DAV1D_COMMIT" && { log "dav1d up to date"; return; }
  log "building dav1d $DAV1D_TAG"
  rm -rf "$WORK_DIR/dav1d"
  meson setup "$WORK_DIR/dav1d" "$SRC_DIR/dav1d" \
    --prefix="$PREFIX_DIR" --libdir=lib --buildtype=release \
    --default-library=static -Denable_tools=false -Denable_tests=false
  ninja -C "$WORK_DIR/dav1d" -j "$JOBS"
  ninja -C "$WORK_DIR/dav1d" install
  set_stamp dav1d "$DAV1D_COMMIT"
}

# ===========================================================================
# SVT-AV1 -- AV1 encoder.
# ===========================================================================
build_svtav1() {
  have_stamp svtav1 "$SVTAV1_COMMIT" && { log "SVT-AV1 up to date"; return; }
  log "building SVT-AV1 $SVTAV1_TAG"
  rm -rf "$WORK_DIR/svt-av1"
  cmake -S "$SRC_DIR/svt-av1" -B "$WORK_DIR/svt-av1" -G Ninja \
    -DCMAKE_INSTALL_PREFIX="$PREFIX_DIR" -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF -DBUILD_APPS=OFF -DBUILD_TESTING=OFF \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON
  cmake --build "$WORK_DIR/svt-av1" -j "$JOBS"
  cmake --install "$WORK_DIR/svt-av1"
  set_stamp svtav1 "$SVTAV1_COMMIT"
}

# ===========================================================================
# libaom -- reference AV1. Needed for the libaom-av1 DECODER too: it is the
# second entry in nelux's chain (Decoder.cpp:151).
# ===========================================================================
build_aom() {
  have_stamp aom "$AOM_COMMIT" && { log "libaom up to date"; return; }
  log "building libaom $AOM_TAG"
  rm -rf "$WORK_DIR/aom"
  cmake -S "$SRC_DIR/aom" -B "$WORK_DIR/aom" -G Ninja \
    -DCMAKE_INSTALL_PREFIX="$PREFIX_DIR" -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF -DENABLE_TESTS=OFF -DENABLE_EXAMPLES=OFF \
    -DENABLE_TOOLS=OFF -DENABLE_DOCS=OFF -DCONFIG_AV1_HIGHBITDEPTH=1 \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON
  cmake --build "$WORK_DIR/aom" -j "$JOBS"
  cmake --install "$WORK_DIR/aom"
  set_stamp aom "$AOM_COMMIT"
}

# ===========================================================================
# libvpx -- VP8/VP9. TAS needs libvpx-vp9 (encodingSettings.py:268-269).
# ===========================================================================
build_vpx() {
  have_stamp vpx "$VPX_COMMIT" && { log "libvpx up to date"; return; }
  log "building libvpx $VPX_TAG"
  rm -rf "$WORK_DIR/libvpx"; mkdir -p "$WORK_DIR/libvpx"
  local target=""
  case "$OS-$ARCH" in
    windows-x86_64) target="--target=x86_64-win64-gcc" ;;
    macos-arm64)    target="--target=arm64-darwin20-gcc" ;;
    macos-x86_64)   target="--target=x86_64-darwin17-gcc" ;;
    # libvpx's own detector calls aarch64 Linux "arm64-linux-gcc". Left
    # explicit because its autodetect has historically guessed armv7 from
    # `uname -m` on some containers, which then fails at assembly time.
    linux-arm64)    target="--target=arm64-linux-gcc" ;;
  esac
  ( cd "$WORK_DIR/libvpx"
    "$SRC_DIR/libvpx/configure" --prefix="$PREFIX_DIR" $target \
      --enable-vp8 --enable-vp9 --enable-vp9-highbitdepth \
      --enable-static --disable-shared --enable-pic \
      --disable-examples --disable-tools --disable-docs --disable-unit-tests
    make -j"$JOBS" && make install )
  set_stamp vpx "$VPX_COMMIT"
}

# ===========================================================================
# libopus -- TAS muxes Opus into .webm (ffmpegSettings.py:848-850).
# ===========================================================================
build_opus() {
  have_stamp opus "$OPUS_COMMIT" && { log "opus up to date"; return; }
  log "building opus $OPUS_TAG"
  rm -rf "$WORK_DIR/opus"
  cmake -S "$SRC_DIR/opus" -B "$WORK_DIR/opus" -G Ninja \
    -DCMAKE_INSTALL_PREFIX="$PREFIX_DIR" -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF -DOPUS_BUILD_PROGRAMS=OFF -DOPUS_BUILD_TESTING=OFF \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON
  cmake --build "$WORK_DIR/opus" -j "$JOBS"
  cmake --install "$WORK_DIR/opus"
  set_stamp opus "$OPUS_COMMIT"
}

# ===========================================================================
# OpenH264 -- the last entry in nelux's default-encoder probe
# (Nelux/src/Nelux/python/VideoEncoder.cpp:46,49,51).
#
# Built with MESON, not the upstream Makefile: FFmpeg's configure:7343 wants
# `pkg-config openh264 >= 1.3.0`, and openh264's meson.build:213 imports the
# pkgconfig module and generates openh264.pc with the project version. The
# hand-written Makefile's install-static target does emit a .pc too, but the
# meson path also gives us a normal static/PIC build on all three OSes with
# no per-OS ARCH=/OS= variables to get wrong. meson+ninja are already
# required by dav1d, so this adds no build tooling.
# ===========================================================================
build_openh264() {
  have_stamp openh264 "$OPENH264_COMMIT" && { log "openh264 up to date"; return; }
  log "building openh264 $OPENH264_TAG"
  rm -rf "$WORK_DIR/openh264"
  meson setup "$WORK_DIR/openh264" "$SRC_DIR/openh264" \
    --prefix="$PREFIX_DIR" --libdir=lib --buildtype=release \
    --default-library=static -Dtests=disabled
  ninja -C "$WORK_DIR/openh264" -j "$JOBS"
  ninja -C "$WORK_DIR/openh264" install
  # openh264 is C++, but meson's pkgconfig module does not add a C++ runtime
  # to Libs.private for a static library -- so the .pc it generates cannot
  # satisfy configure:7343's require_pkg_config link test (undefined
  # operator new / __cxa_*) on ANY platform. Note this is checked BEFORE x265
  # (:7432), so it is the first thing that would die.
  pc_fix_cxx "$PREFIX_DIR/lib/pkgconfig/openh264.pc"
  set_stamp openh264 "$OPENH264_COMMIT"
}

# ===========================================================================
# libvmaf -- backs the `libvmaf` FILTER.
#
# NOT optional and NOT a benchmark nicety: Nelux/tests/test_software_encoders
# .py is a real pytest module whose quality gate at :181 runs
#     [0:v][1:v]libvmaf=feature='name=psnr|name=float_ssim'
# through the bundled ffmpeg and RAISES RuntimeError at :198 on failure. It
# pytest.skip()s only when ffmpeg/ffprobe are missing (:171,:221), so a build
# without this filter turns that whole parametrised suite RED.
#
# Two build details that are easy to get wrong:
#   * the meson project is in the repo's `libvmaf/` SUBDIRECTORY, not at the
#     repo root;
#   * `float_ssim` is a FLOAT feature extractor -- pass -Denable_float=true
#     explicitly rather than trusting the default, because that default has
#     changed between libvmaf 2.x and 3.x.
# built_in_models is left at its default (on) so no runtime .json model files
# have to be shipped or located.
# ===========================================================================
build_vmaf() {
  have_stamp vmaf "$VMAF_COMMIT" && { log "libvmaf up to date"; return; }
  log "building libvmaf $VMAF_TAG"
  rm -rf "$WORK_DIR/vmaf"
  meson setup "$WORK_DIR/vmaf" "$SRC_DIR/vmaf/libvmaf" \
    --prefix="$PREFIX_DIR" --libdir=lib --buildtype=release \
    --default-library=static -Denable_float=true \
    -Denable_tests=false -Denable_docs=false -Dbuilt_in_models=true
  ninja -C "$WORK_DIR/vmaf" -j "$JOBS"
  ninja -C "$WORK_DIR/vmaf" install
  # Same treatment as openh264: libvmaf's build pulls in C++ translation
  # units and meson emits no C++ runtime in Libs.private. configure:7391
  # checks it with require_pkg_config -- also BEFORE x265 -- so a missing
  # runtime aborts the build there. Harmless if libvmaf happens to be pure C
  # on a given release: naming the platform's C++ runtime pulls nothing out of
  # it when nothing references it.
  pc_fix_cxx "$PREFIX_DIR/lib/pkgconfig/libvmaf.pc"
  set_stamp vmaf "$VMAF_COMMIT"
}

# ===========================================================================
# GnuTLS + its two dependencies -- LINUX ONLY.
#
# Windows uses Schannel and macOS SecureTransport (both system frameworks,
# zero extra dependencies). Linux has no such thing, and ffmpeg-8.1.2's
# configure rejects every other backend in a GPL build:
#     :7382-7383  LibreSSL       -> "incompatible with the gpl"
#     :7493       OpenSSL >= 3.0 -> "requires --enable-version3"
#     :7494       OpenSSL <  3.0 -> "incompatible with the gpl"
#     :2007-2016  mbedtls is in EXTERNAL_LIBRARY_VERSION3_LIST
# so GnuTLS is the only option. See flags/ffmpeg.linux.flags for WHY TLS is
# required at all (yt-dlp's FFmpegFD fallback runs OUR ffmpeg against an
# https m3u8 URL -- Theanimescripter/src/ytdlp.py:184,202).
#
# Everything static, everything from the pinned tarball, nothing from the
# manylinux image -- otherwise libavformat.so grows a runtime dependency on
# libgnutls.so.30 that neither consumer ships, and verify-output.sh's import
# allowlist would (correctly) fail the build.
#
# libtasn1 and libunistring are taken with --with-included-*, and p11-kit is
# refused, so the dependency chain stops at gmp+nettle instead of continuing
# into the distro.
# ===========================================================================
build_gnutls() {
  [ "$OS" = "linux" ] || { log "skipping GnuTLS ($OS uses the system TLS backend)"; return; }
  have_stamp gnutls "$GNUTLS_VERSION-$NETTLE_VERSION-$GMP_VERSION" \
    && { log "GnuTLS stack up to date"; return; }

  log "building gmp $GMP_VERSION"
  rm -rf "$WORK_DIR/gmp"; mkdir -p "$WORK_DIR/gmp"
  tar -C "$WORK_DIR/gmp" --strip-components=1 -xf "$SRC_DIR/gmp-$GMP_VERSION.tar.xz"
  ( cd "$WORK_DIR/gmp"
    # --enable-fat gives runtime CPU dispatch on x86_64 (same rule as
    # --enable-runtime-cpudetect for FFmpeg: one artefact, every machine).
    # It is x86-only in gmp, hence the guard.
    fat=""
    [ "$ARCH" = "x86_64" ] && fat="--enable-fat"
    ./configure --prefix="$PREFIX_DIR" --enable-static --disable-shared \
                --with-pic --disable-cxx $fat
    make -j"$JOBS" && make install )

  log "building nettle $NETTLE_VERSION"
  rm -rf "$WORK_DIR/nettle"; mkdir -p "$WORK_DIR/nettle"
  tar -C "$WORK_DIR/nettle" --strip-components=1 -xf "$SRC_DIR/nettle-$NETTLE_VERSION.tar.gz"
  ( cd "$WORK_DIR/nettle"
    ./configure --prefix="$PREFIX_DIR" --enable-static --disable-shared \
                --disable-documentation --disable-openssl \
                --libdir="$PREFIX_DIR/lib" \
                CPPFLAGS="-I$PREFIX_DIR/include" LDFLAGS="-L$PREFIX_DIR/lib"
    make -j"$JOBS" && make install )

  log "building gnutls $GNUTLS_VERSION"
  rm -rf "$WORK_DIR/gnutls"; mkdir -p "$WORK_DIR/gnutls"
  tar -C "$WORK_DIR/gnutls" --strip-components=1 -xf "$SRC_DIR/gnutls-$GNUTLS_VERSION.tar.xz"
  ( cd "$WORK_DIR/gnutls"
    ./configure --prefix="$PREFIX_DIR" --enable-static --disable-shared \
                --with-included-libtasn1 --with-included-unistring \
                --without-p11-kit --without-tpm --without-tpm2 \
                --disable-doc --disable-tools --disable-tests \
                --disable-cxx --disable-guile --disable-libdane \
                --with-pic \
                NETTLE_CFLAGS="-I$PREFIX_DIR/include" \
                NETTLE_LIBS="-L$PREFIX_DIR/lib -lnettle" \
                HOGWEED_CFLAGS="-I$PREFIX_DIR/include" \
                HOGWEED_LIBS="-L$PREFIX_DIR/lib -lhogweed -lnettle -lgmp" \
                GMP_CFLAGS="-I$PREFIX_DIR/include" \
                GMP_LIBS="-L$PREFIX_DIR/lib -lgmp"
    make -j"$JOBS" && make install )

  set_stamp gnutls "$GNUTLS_VERSION-$NETTLE_VERSION-$GMP_VERSION"
}

# ===========================================================================
# libzimg -- backs the zscale filter that TAS uses for its BT.2020 path
# (Theanimescripter/src/io/ffmpegSettings.py:797). Required by TAS; included
# for nelux too under the union rule (one build, one artefact set).
# ===========================================================================
build_zimg() {
  have_stamp zimg "$ZIMG_COMMIT" && { log "zimg up to date"; return; }
  log "building zimg $ZIMG_TAG"
  rm -rf "$WORK_DIR/zimg"; cp -r "$SRC_DIR/zimg" "$WORK_DIR/zimg"
  ( cd "$WORK_DIR/zimg"
    # zimg ships no pre-generated configure: autogen.sh runs `autoreconf -if`,
    # which needs autoconf + automake + libtool. The macOS CI leg installs
    # them from Homebrew (.github/workflows/build.yml), where libtoolize is
    # called `glibtoolize` -- Homebrew keeps the GNU names out of PATH so they
    # cannot shadow Apple's /usr/bin/libtool. autoreconf looks the tool up
    # through the LIBTOOLIZE environment variable first, so this is the fix
    # that does not require putting Homebrew's gnubin on PATH (which WOULD
    # shadow /usr/bin/libtool and break the x265 archive merge above).
    if [ "$OS" = "macos" ] && command -v glibtoolize >/dev/null 2>&1; then
      export LIBTOOLIZE=glibtoolize
    fi
    ./autogen.sh
    ./configure --prefix="$PREFIX_DIR" --enable-static --disable-shared --with-pic
    make -j"$JOBS" && make install )
  # zimg is C++ and zimg.pc.in carries -lstdc++ in Libs.private; see
  # pc_fix_cxx. configure:7441 checks it with require_pkg_config.
  pc_fix_cxx "$PREFIX_DIR/lib/pkgconfig/zimg.pc"
  set_stamp zimg "$ZIMG_COMMIT"
}

# ---------------------------------------------------------------------------
build_zlib
build_bzip2
build_xz
build_libiconv
build_nvcodec
build_amf
build_libvpl
# libdrm before libva: libva/meson.build:88 requires libdrm >= 2.4.75 and both
# resolve through $PREFIX_DIR/lib/pkgconfig. Both no-op off linux/x86_64.
build_libdrm
build_libva
build_x264
build_x265
build_openh264
build_dav1d
build_svtav1
build_aom
build_vpx
build_opus
build_zimg
build_vmaf
build_gnutls

log "dependencies for $OS/$ARCH are in $PREFIX_DIR"
