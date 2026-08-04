#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/lib/common.sh -- shared helpers. Sourced, never executed.
# Portable bash: must run under MSYS2 (Windows), manylinux_2_28 (Linux) and
# macOS's /bin/bash 3.2 as well as a modern bash. No bash-4-only syntax.
# ---------------------------------------------------------------------------

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOCK_FILE="$REPO_ROOT/versions.lock"

BUILD_ROOT="${BUILD_ROOT:-$REPO_ROOT/build}"
SRC_DIR="${SRC_DIR:-$BUILD_ROOT/sources}"      # pristine, verified sources
WORK_DIR="${WORK_DIR:-$BUILD_ROOT/work}"       # extracted + object trees
PREFIX_DIR="${PREFIX_DIR:-$BUILD_ROOT/deps}"   # where deps install
OUT_DIR="${OUT_DIR:-$BUILD_ROOT/out}"          # staged install trees
DIST_DIR="${DIST_DIR:-$REPO_ROOT/dist}"        # final archives

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

# --- versions.lock ---------------------------------------------------------
# The lock file is deliberately restricted to `KEY=value` lines so it can be
# parsed by non-shell tools. We still validate that before sourcing, because
# sourcing an untrusted file is otherwise arbitrary code execution.
load_lock() {
  [ -f "$LOCK_FILE" ] || die "versions.lock not found at $LOCK_FILE"
  local bad
  # The value charset is an allowlist, not a denylist: it is what makes
  # `source`-ing this file safe.
  #
  # ',' is permitted so *_URL can hold a mirror list (see fetch_tarball). It is
  # genuinely inert: bash treats a bare comma as an ordinary character, and the
  # one construct that gives it meaning -- brace expansion, {a,b} -- needs
  # braces, which this allowlist excludes.
  #
  # '|' was tried first and is NOT safe here, which cost a CI round. The lock
  # is SOURCED, so a metacharacter matters at parse time, not merely inside the
  # expansions the scripts perform:
  #     GMP_URL=https://a|https://b
  # parses as an assignment piped into a command named `https://b` and exits
  # 127. Everything else that can execute -- $ ` ; & ( ) < > ' " { } and space
  # -- stays excluded for the same reason. Do not widen this without checking
  # what the character does to the PARSER.
  bad="$(grep -vE '^[[:space:]]*(#.*)?$|^[A-Z][A-Z0-9_]*=[A-Za-z0-9._:/@+,-]*$' "$LOCK_FILE" || true)"
  if [ -n "$bad" ]; then
    die "versions.lock contains lines that are not plain KEY=value:
$bad"
  fi
  # shellcheck disable=SC1090
  . "$LOCK_FILE"
}

# require_lock KEY... -- fail loudly if a pin is empty rather than building
# something unpinned.
require_lock() {
  local k v
  for k in "$@"; do
    eval "v=\${$k:-}"
    [ -n "$v" ] || die "versions.lock: $k is empty or missing (unpinned input)"
  done
}

# ---------------------------------------------------------------------------
# Dependency inventory -- DERIVED FROM versions.lock, never hand-maintained.
#
# WHY: scripts/corresponding-source.sh and scripts/package.sh used to carry
# two hand-written lists of dependency names. Both drifted. When openh264,
# libvmaf, GMP, Nettle and GnuTLS were added as real, linked dependencies,
# neither list was updated, so the release would have shipped GPL binaries
# whose "complete corresponding source" archive omitted five components and
# whose licenses/ directory omitted five licences. The `rc=1` guard in
# corresponding-source.sh could not catch it: it only checked that the names
# ALREADY IN THE LIST resolved. GnuTLS is LGPL-2.1-or-later, so that is a
# real licence violation, not a tidiness problem.
#
# The fix is to stop maintaining a second list. These helpers read the pins
# themselves, so adding a *_REPO or a *_URL to versions.lock automatically
# makes that component required by BOTH the source archive and the licence
# collection, and forgetting to teach dep_dir() about it is a hard failure.
#
# lock_dep_keys -- prints "<PREFIX> <kind>" for every pinned third-party
# component, one per line. kind is:
#     git      -> a checkout lives at $SRC_DIR/$(dep_dir PREFIX), pinned by
#                 <PREFIX>_COMMIT
#     tarball  -> the archive lives at $SRC_DIR/$(dep_tarball PREFIX), pinned
#                 by <PREFIX>_SHA256
# FFmpeg itself is excluded: it is handled explicitly everywhere (the upstream
# signed tarball is shipped byte for byte), and so is its detached signature.
lock_dep_keys() {
  sed -n \
    -e 's/^\([A-Z][A-Z0-9_]*\)_REPO=.*/\1 git/p' \
    -e 's/^\([A-Z][A-Z0-9_]*\)_URL=.*/\1 tarball/p' \
    "$LOCK_FILE" \
    | grep -vE '^(FFMPEG|FFMPEG_SIG) ' \
    | sort -u
}

# dep_dir PREFIX -- the directory name this component is fetched into
# ($SRC_DIR/<dir> for git, $WORK_DIR/<dir> once a tarball is unpacked) and the
# name used for licenses/<dir>/ in the shipped archives.
#
# An UNKNOWN prefix is a hard failure on purpose. It is the tripwire that
# makes the derivation above safe: a new pin in versions.lock cannot be
# packaged until someone states where its source and its licence live.
dep_dir() {
  case "$1" in
    NVCODEC)  echo nv-codec-headers ;;
    X264)     echo x264             ;;
    X265)     echo x265             ;;
    OPENH264) echo openh264         ;;
    DAV1D)    echo dav1d            ;;
    SVTAV1)   echo svt-av1          ;;
    AOM)      echo aom              ;;
    VPX)      echo libvpx           ;;
    OPUS)     echo opus             ;;
    ZIMG)     echo zimg             ;;
    ZLIB)     echo zlib             ;;
    VMAF)     echo vmaf             ;;
    LIBVPL)   echo libvpl           ;;
    AMF)      echo AMF              ;;
    BZIP2)    echo bzip2            ;;
    XZ)       echo xz               ;;
    LIBICONV) echo libiconv         ;;
    GMP)      echo gmp              ;;
    NETTLE)   echo nettle           ;;
    GNUTLS)   echo gnutls           ;;
    *) die "versions.lock pins '$1' but scripts/lib/common.sh dep_dir() does
not know where its source tree and licence live. Add a case for it.
This check exists because openh264, libvmaf, GMP, Nettle and GnuTLS were
once added as real dependencies while the corresponding-source archive and
the shipped licences/ directory silently kept ignoring them." ;;
  esac
}

# dep_tarball PREFIX -- basename of <PREFIX>_URL, i.e. the file fetch-sources
# .sh leaves in $SRC_DIR for a tarball-distributed component.
#
# <PREFIX>_URL may be a ','-separated mirror list (see fetch_tarball), so take
# the FIRST entry rather than basename'ing the whole string. Doing the latter
# happens to work while every mirror ends in the same filename, and silently
# returns the wrong name the moment one does not -- e.g. a mirror serving
# `download?file=gmp-6.3.0.tar.xz`.
dep_tarball() {
  local u
  eval "u=\${$1_URL:-}"
  [ -n "$u" ] || die "dep_tarball: ${1}_URL is not set in versions.lock"
  basename "${u%%,*}"
}

# --- platform detection ----------------------------------------------------
detect_os() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) echo windows ;;
    Linux)                echo linux   ;;
    Darwin)               echo macos   ;;
    *) die "unsupported build host: $(uname -s)" ;;
  esac
}

# We never cross-compile: TARGET_ARCH names which NATIVE build this is.
# macOS has two (arm64 / x86_64 runners) and Linux has two (x86_64 /
# aarch64 manylinux_2_28 containers). It also selects
# flags/ffmpeg.<os>.<arch>.flags, so on linux/arm64 it is what turns QSV,
# VAAPI and AMF off.
detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo x86_64 ;;
    arm64|aarch64) echo arm64 ;;
    *) die "unsupported arch: $(uname -m)" ;;
  esac
}

# --- fetching + verification ----------------------------------------------
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum   >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else die "no sha256sum/shasum available"
  fi
}

# fetch_tarball URL[,URL...] DEST EXPECTED_SHA256
#
# URL may be a ','-separated list of mirrors, tried left to right until one
# yields bytes. The FIRST url should be the most reliable host, not
# necessarily the upstream one.
#
# Mirrors are safe here precisely because every artefact is pinned by SHA256:
# a hostile or stale mirror cannot substitute content without failing the
# check below, so the only thing a mirror can do is fail. The alternative --
# a single canonical host -- means one unreachable server stops every build
# on every platform, which is exactly what happened on the first full CI run:
#     curl: (28) Failed to connect to gmplib.org:443 after 21200 ms
# took out Windows, macOS arm64 and macOS x86_64 simultaneously, four retries
# each, while ftp.gnu.org was serving a byte-identical tarball the whole time.
fetch_tarball() {
  local urls="$1" dest="$2" want="$3" got url ok=0
  mkdir -p "$(dirname "$dest")"
  if [ -f "$dest" ]; then
    got="$(sha256_of "$dest")"
    if [ "$got" = "$want" ]; then log "cached, verified: $(basename "$dest")"; return 0; fi
    warn "cached $(basename "$dest") has wrong SHA256, refetching"
    rm -f "$dest"
  fi
  local IFS=','
  # shellcheck disable=SC2206  # deliberate split on ','
  local mirror_list=($urls)
  unset IFS
  for url in "${mirror_list[@]}"; do
    [ -n "$url" ] || continue
    log "fetching $url"
    # --max-time bounds a black-holed host. gmplib.org burned 75s per attempt
    # on the macOS runners before curl gave up on its own.
    if curl -fsSL --retry 3 --retry-delay 5 --connect-timeout 20 --max-time 600 \
            -o "$dest" "$url"; then
      ok=1
      break
    fi
    warn "mirror failed: $url"
    rm -f "$dest"
  done
  [ "$ok" -eq 1 ] || die "all mirrors failed for $(basename "$dest"):
$(printf '  %s\n' "${mirror_list[@]}")"
  got="$(sha256_of "$dest")"
  [ "$got" = "$want" ] || die "SHA256 MISMATCH for $url
  expected $want
  got      $got
This is either a corrupted download or a changed upstream artefact. Do not
proceed. If upstream legitimately republished, update versions.lock in a
reviewed commit."
  log "verified $(basename "$dest")"
}

# restore_pin_tag DEST_DIR COMMIT TAG
#
# `fetch_git` clones with `git init` + `fetch --depth 1 origin <sha>`. That is
# the right way to pin by commit, but it brings down NO REFS AT ALL: the
# resulting checkout has an empty `git tag` list, and every `git describe` in
# it fails with "fatal: No names found, cannot describe anything."
#
# For most dependencies that is cosmetic. For x265 it is FATAL, in two
# different places, and it took out three of the five build legs at once:
#
#   x265/source/cmake/Version.cmake:144-151 runs
#       git describe --abbrev=0 --tags
#   into OUTPUT_VARIABLE X265_LATEST_TAG with ERROR_QUIET. A tagless clone
#   makes that the EMPTY STRING -- note it overwrites the "0.0" default set
#   at Version.cmake:29, so the fallback never applies. Then:
#
#   1. x265/source/CMakeLists.txt:1113
#          if(X265_LATEST_TAG OR NOT GIT_FOUND)
#      is false (empty tag, git present), so the ENTIRE pkg-config block --
#      including CMakeLists.txt:1133-1135's `configure_file`/`install` of
#      x265.pc -- is skipped. x265 builds, installs libx265.a and its
#      headers, and simply never writes lib/pkgconfig/x265.pc. FFmpeg's
#      configure:7432 `require_pkg_config libx265 x265 ...` is a hard die, so
#      BOTH Linux legs got through the whole 15-minute dependency build and
#      then failed with
#          ERROR: x265 not found using pkg-config
#
#   2. x265/source/CMakeLists.txt:1041-1043
#          string(REGEX MATCHALL "([0-9]+)" VERSION_LIST "${X265_LATEST_TAG}")
#          list(GET VERSION_LIST 0 X265_VERSION_MAJOR)
#          list(GET VERSION_LIST 1 X265_VERSION_MINOR)
#      runs only `if(CMAKE_RC_COMPILER)`, i.e. only where a resource compiler
#      exists -- MinGW on Windows. MATCHALL over an empty tag yields an empty
#      list, so both `list(GET ...)` calls abort:
#          CMake Error at CMakeLists.txt:1042 (list):
#            list GET given empty list
#      That is why Windows died at x265's CONFIGURE step while Linux got as
#      far as FFmpeg's, from the same root cause.
#
# The fix is to put back the one piece of metadata the shallow fetch dropped:
# a local lightweight tag at the pinned commit, named with the tag from
# versions.lock. This does not weaken the pin -- the COMMIT is still what is
# fetched, checked out and asserted; the tag is a label attached to an object
# we have already verified by SHA, not a thing we resolve anything from.
#
# Applied to every dependency rather than special-cased for x265, because
# "shallow clone has no tags" is a property of fetch_git, not of x265, and
# several other deps derive their version string from `git describe` too
# (libaom, libvpx, opus). Those currently report an unknown version; with the
# tag they report the pinned one.
#
# EVERY FAILURE PATH IN HERE USED TO BE SILENT, and that hid a real defect for
# a full round: on the Windows leg the opus checkout came out with no tags at
# all, so opus/cmake/OpusPackageVersion.cmake:11-12's
#     git --git-dir=<src>/.git describe --tags --match "v*"
# printed "fatal: No names found, cannot describe anything", CMake warned
# "Could not get package version", and opus built as VERSION 0 -- while the
# SAME code produced "Opus package version from git repo: 1.6.1" on both Linux
# and macOS. Nothing said why, because the two `return 0`s and the `|| true`
# below swallow git's own message. They still do not abort a fetch (a label is
# not worth failing a build over), but they now SAY SO, with git's stderr.
restore_pin_tag() {
  local dest="$1" commit="$2" tag="${3:-}" err
  [ -n "$tag" ] || return 0
  # Already there (the full-fetch fallback below uses --tags, so real tags can
  # be present) -- leave upstream's own tag object alone.
  git -C "$dest" rev-parse -q --verify "refs/tags/$tag" >/dev/null 2>&1 && return 0
  # Not every *_TAG in versions.lock is an upstream tag: X264_TAG is the date
  # label `master@2025-09-10` (x264 publishes no release tags). git accepts
  # that as a ref name and it is inert -- x264's own version.sh:9-27 derives
  # its version from `git rev-list HEAD | wc -l`, never from `git describe`,
  # and under --depth 1 that count is 1 so the whole branch is skipped. But
  # `..`, `~`, `^`, a trailing `.lock` and friends are NOT legal ref names, so
  # ask git rather than guessing, and skip quietly rather than failing a fetch
  # over a label that only ever mattered as documentation.
  if ! git check-ref-format "refs/tags/$tag" >/dev/null 2>&1; then
    warn "$(basename "$dest"): '$tag' is not a legal git ref name, so no local
tag was attached. Anything in this dependency that derives its version from
\`git describe\` will report an unknown version."
    return 0
  fi
  err="$(git -C "$dest" tag -f "$tag" "$commit" 2>&1 >/dev/null || true)"
  if ! git -C "$dest" rev-parse -q --verify "refs/tags/$tag" >/dev/null 2>&1; then
    warn "$(basename "$dest"): could not attach the pin tag '$tag' to $commit.
git said: ${err:-(nothing)}
The checkout is still correct -- the COMMIT is what is verified -- but any
dependency that runs \`git describe\` in it will build with an unknown
version, which lands in its generated .pc file. See build_x265 in
scripts/build-deps.sh for the case where that is fatal rather than cosmetic."
  fi
}

# fetch_git REPO COMMIT DEST_DIR [TAG]
# Pins by COMMIT, never by tag: a moved tag becomes a hard failure. TAG is
# used for the log line and, via restore_pin_tag above, re-attached locally to
# the verified commit so dependency build systems that call `git describe`
# still work in a shallow checkout.
fetch_git() {
  local repo="$1" commit="$2" dest="$3" tag="${4:-}" have
  if [ -d "$dest/.git" ]; then
    have="$(git -C "$dest" rev-parse HEAD)"
    if [ "$have" = "$commit" ]; then
      # The tag restore MUST happen on this path too, not only after a fresh
      # clone. build/sources is restored by actions/cache keyed on
      # hashFiles('versions.lock'), so an unchanged pin set means every CI job
      # takes this early return -- and a cache populated by an older run holds
      # exactly the tagless checkouts described above.
      restore_pin_tag "$dest" "$commit" "$tag"
      log "cached, verified: $(basename "$dest") @ $commit"
      return 0
    fi
    warn "$(basename "$dest") at $have, want $commit -- refetching"
    rm -rf "$dest"
  fi
  mkdir -p "$(dirname "$dest")"
  log "cloning $repo @ ${tag:-$commit}"
  git init -q "$dest"
  git -C "$dest" remote add origin "$repo"
  # Try a shallow fetch of the exact object first (works on GitHub/GitLab);
  # fall back to a full fetch for servers with uploadpack.allowReachableSHA1
  # disabled (aomedia.googlesource.com historically).
  if ! git -C "$dest" fetch -q --depth 1 origin "$commit" 2>/dev/null; then
    warn "server refused single-commit fetch, falling back to full fetch"
    git -C "$dest" fetch -q --tags origin
  fi
  git -C "$dest" checkout -q "$commit" \
    || die "commit $commit not found in $repo (bad pin in versions.lock?)"
  have="$(git -C "$dest" rev-parse HEAD)"
  [ "$have" = "$commit" ] || die "post-checkout HEAD is $have, expected $commit"
  # Only now that HEAD has been asserted equal to the pinned commit -- so the
  # label can only ever be attached to a verified object.
  restore_pin_tag "$dest" "$commit" "$tag"
  # Submodules are pinned transitively by the superproject's gitlink, so this
  # stays deterministic.
  git -C "$dest" submodule update -q --init --recursive --depth 1 2>/dev/null || true
  log "verified $(basename "$dest") @ $commit"
}

# --- misc ------------------------------------------------------------------
nproc_portable() {
  if command -v nproc >/dev/null 2>&1; then nproc
  elif command -v sysctl >/dev/null 2>&1; then sysctl -n hw.ncpu
  else echo 4
  fi
}

# The archive/basename used everywhere. ONE build serves both consumers, so
# there is no profile component in the name -- only version and platform.
# Format is deliberately close to BtbN's so TheAnimeScripter's existing
# extraction code (src/infra/getFFMPEG.py:316-335) needs only a URL change.
artifact_name() {  # artifact_name <os> <arch> -> tas-ffmpeg-8.1.2-win64
  local os="$1" arch="$2" plat
  case "$os-$arch" in
    windows-x86_64) plat=win64 ;;
    linux-x86_64)   plat=linux64 ;;
    linux-arm64)    plat=linuxarm64 ;;
    macos-arm64)    plat=macos-arm64 ;;
    macos-x86_64)   plat=macos-x86_64 ;;
    *) die "no artifact name mapping for $os-$arch" ;;
  esac
  echo "tas-ffmpeg-$FFMPEG_VERSION-$plat"
}
