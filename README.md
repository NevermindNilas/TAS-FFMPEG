# tas-ffmpeg

Pinned, reproducible, GPL FFmpeg builds for **nelux** and **TheAnimeScripter**.

One build. **Five targets** — `win64`, `linux64`, `linuxarm64`, `macos-arm64`,
`macos-x86_64`. Every input pinned by tag *and* commit SHA (or tarball
SHA256), verified on fetch, and republished as a corresponding-source archive
so the GPL obligation is actually satisfiable.

> **Status: nothing here has been compiled yet.** This repository is complete,
> reviewable build infrastructure. See [What is unverified](#unverified) — it
> is the most important section in this file.
>
> What *has* been exercised, against a real FFmpeg 8.1.2 GPL shared build:
> `scripts/validate-flags.sh` (every flag name, all five targets) and
> `scripts/verify-output.sh` (all nine assertion groups, including the
> 171-line component contract). Neither has ever seen a binary *we* produced.

---

## Why this exists

Both consumers currently get FFmpeg from third parties:

| Consumer | Windows | Linux | macOS |
|---|---|---|---|
| nelux (`tools/ffmpeg.lock`) | gyan.dev 8.1.2, BtbN fallback | BtbN `n8.1.2-34-g9b6c8969e0` | Homebrew, **unpinnable** |
| TheAnimeScripter (`src/infra/getFFMPEG.py`) | BtbN autobuild zip | johnvansickle **7.0.2** static | `brew install ffmpeg` |

Three problems with that:

1. **BtbN prunes its `autobuild-*` tags after a few months.** Every pinned URL
   will eventually 404. nelux's own lock file says so at lines 59-68.
2. **macOS is not pinned at all.** `brew install ffmpeg` hands you whatever
   8.x bottle exists that day. It is the one platform that does not land on
   exactly 8.1.2.
3. **The two consumers pin independently** and are expected to hand-mirror
   values between three repositories. nelux's lock file literally instructs a
   human to do this (lines 16-20). That is a drift generator, and drift here
   is not cosmetic — see [Drift](#drift).

This repo builds exactly **FFmpeg n8.1.2** from source, from pinned
dependencies, and publishes one `ffmpeg-pin.lock` that both consumers vendor.

---

## One build, not two

An earlier design split this into a slim `nelux-min` (five libraries, no
programs, trimmed encoders) and a fat `tas-full`. **That split has been
dropped.** The owner's rule is the union: if either consumer needs a feature,
it is in.

Practically this means the build is close to a stock full GPL build:

- **All seven libraries** — `avcodec avdevice avfilter avformat avutil
  swresample swscale`.
- **The CLI programs** — `ffmpeg` and `ffprobe`. TAS shells out to both and
  hard-fails if either is missing (`Theanimescripter/src/cli/startup.py:81`).
- **Shared libraries on every platform.** nelux bundles them in its wheel and
  delay-loads them; TAS flattens them into `ffmpeg_shared/` and calls
  `os.add_dll_directory()` on that folder *specifically so nelux can
  delay-load from there*.
- **No `--disable-encoders` / `--disable-muxers` / `--disable-filters`.**

The nelux **library** does not call into `avfilter` or `avdevice`. Verified:
`Nelux/include/Nelux/CxCore.hpp:43-45` includes the avfilter headers and
`:97-103,126` define `AVFilterGraphDeleter` / `AVFilterGraphPtr`, but a
repo-wide grep returns those two definitions and **zero** uses — an unused
`unique_ptr` deleter emits no code. `av_buffersrc_*`, `av_buffersink_*` and
`avdevice_*` have **0 hits** in `Nelux/src` and `Nelux/include`. Both are
still hard-linked: `Nelux/CMakeLists.txt:307` lists all seven components and
`FATAL_ERROR`s at `:313-319` if a `.def` is missing, and
`FFmpegDelayLoad.cpp:56` names them, so building all seven means **no nelux
change at all**.

But "union courtesy" undersells `avdevice`. nelux's **test suite** needs it:
`tests/test_codec_container_parity.py:38-42` generates its media with

```python
subprocess.run([FFMPEG, ..., "-f", "lavfi", "-i", "testsrc2=...", ...],
               check=True, ...)
```

`lavfi` is an **input device**, so it lives in `libavdevice` and requires
`--enable-avdevice`. With `check=True` this raises rather than skips. Six more
benchmark scripts do the same. `flags/required-components.txt` therefore
asserts `device lavfi` after every build.

---

## <a id="custom-encoder"></a>The `--custom_encoder` caveat

**Arbitrary `--custom_encoder` flags may reference features not built into
these binaries.** This is unavoidable, and it is why the build is generous.

`Theanimescripter/src/cli/parser.py:1278-1280` declares:

```python
encodingGroup.add_argument("--custom_encoder", type=str, default="",
                           help="Custom encoder settings")
```

No `choices=`. No validation. It is whitespace-split at
`src/io/ffmpegSettings.py:825` (`self.custom_encoder.split()`) and spliced
verbatim into the command line at `:744`, where it **replaces**
`matchEncoder()`'s output entirely. TAS-Standalone re-exports it as free text
to the user (`src/shared/schema.ts:462`).

The required feature set is therefore **unbounded by construction**. No static
analysis of TAS can ever close it, and no amount of auditing this repo will
either — the two facts are independent. `flags/required-components.txt` pins
down everything the two codebases *demonstrably* reach; `--custom_encoder` sits
outside that boundary permanently, by design, and the honest statement is:

> **Arbitrary `--custom_encoder` flags may reference features not built into
> these binaries, and always will.** The build is deliberately generous — close
> to a stock full GPL build — precisely to make that unlikely rather than to
> pretend it is impossible.

What is *not* built in — and what a `--custom_encoder` user will hit "Unknown
encoder/filter" on — is listed in `flags/ffmpeg.flags` §5:
libass/libfreetype (so no `subtitles=` or `drawtext` burn-in), libmp3lame,
libwebp, libopenjpeg, librav1e, libxvid, libtheora, libvorbis, libsrt,
librist, libplacebo/vulkan, avisynth, and the rest. Each would add another
pinned dependency and more surface to keep building on five targets. If one
turns out to matter: pin it in `versions.lock`, add one line to
`flags/ffmpeg.flags`, add one line to `flags/required-components.txt` so the
build proves it arrived, and add a builder to `scripts/build-deps.sh`.

Two things that *were* on that "not built" list are now in, because evidence
turned up: **libvmaf** (`Nelux/tests/test_software_encoders.py:181` raises at
`:198` without the filter — a test failure, not a skip) and **libopenh264**
(the last entry of nelux's default-encoder probe).

---

## <a id="drift"></a>No build suffix — and why that needs two safeguards

The libraries are named plainly: `avcodec-62.dll`, `libavcodec.so.62`,
`libavcodec.62.dylib`. There is **no `--build-suffix`**.

That means nelux's bundled copy and TAS's `ffmpeg_shared/` copy have identical
file names, and on Windows **whichever loads into the process first serves
both**. This is safe *if and only if* they are byte-identical builds of the
same version — same symbols, same ABI, no mismatch.

**Nothing at the OS level enforces that.** Mismatched FFmpeg builds co-loaded
in one process is undefined behaviour: the delay-load resolver in
`Nelux/src/Nelux/FFmpegDelayLoad.cpp` will happily bind to an already-loaded
`avcodec-62.dll` that was configured differently, and struct layouts,
`AVCodecContext` field offsets and internal ABI all vary with configure flags
even within one soname major. So two safeguards ship with every release:

### 1. `ffmpeg-pin.lock` — one version, both consumers

Published as a release asset by `scripts/emit-consumer-pin.sh`, in the same
`KEY=value` format `Nelux/tools/ffmpeg.lock` already parses (chosen so bash,
PowerShell, Python and GitHub Actions can all read it). Each consumer should
**fetch this file** for the release it targets rather than hand-maintaining
its own URLs and hashes. That replaces the current three-way manual mirroring.

### 2. `manifest.json` — assert at startup, fail loudly

Every archive contains one, written by `scripts/make-manifest.sh`:

```jsonc
{
  "av_version_info": "8.1.2-tas",
  "soname_majors": { "avcodec": 62, "avdevice": 62, "avfilter": 11,
                     "avformat": 62, "avutil": 60,
                     "swresample": 6, "swscale": 9 },
  "artifacts_sha256": { "bin/avcodec-62.dll": "…" }
}
```

`av_version_info()` is a one-call, always-present `libavutil` export returning
the `FFMPEG_VERSION` string. Because the build passes `--extra-version=tas`,
ours is **`8.1.2-tas`** — verified against `ffbuild/version.sh:40`
(`test -n "$3" && version=$version-$3`) and `:48`
(`#define FFMPEG_VERSION "$version"`).

No distro, gyan or BtbN FFmpeg can ever produce that string, so the assertion
catches *"we loaded somebody else's FFmpeg"* as well as *"we loaded an older
one of ours"*.

Each consumer should do, at startup:

```python
expected = json.load(open(".../manifest.json"))
if nelux.ffmpeg_version_info() != expected["av_version_info"]:
    raise RuntimeError(
        f"FFmpeg drift: loaded {nelux.ffmpeg_version_info()}, "
        f"expected {expected['av_version_info']}")
```

**Loading a drifted build must fail loudly, not silently.**

---

## Layout

```
versions.lock                  every pin; nothing else hardcodes a version
flags/
  ffmpeg.flags                 portable configure flags, one per line,
                               each tagged # nelux / # TAS / # both / # union
  ffmpeg.windows.flags         per-OS additions
  ffmpeg.linux.flags
  ffmpeg.linux.arm64.flags     per-ARCH delta (last-wins): no QSV/VAAPI/AMF
  ffmpeg.macos.flags
  required-components.txt      THE CONTRACT -- every encoder/decoder/muxer/
                               demuxer/filter/protocol/bsf/device either
                               consumer reaches, with file:line evidence and
                               a platform selector. verify-output.sh asserts
                               every line against the BUILT BINARY.
scripts/
  build.sh                     one-shot: fetch -> validate -> deps -> ffmpeg -> package
  fetch-sources.sh             fetch + SHA256/PGP/commit verification
  validate-flags.sh            check every flag AND component name vs the real source
  build-deps.sh                build all deps static into build/deps
  build-ffmpeg.sh              configure + make + install
  verify-output.sh             post-build assertions (see below)
  make-manifest.sh             emit manifest.json
  package.sh                   archive + licenses/ + SHA256SUMS
  corresponding-source.sh      the GPL source-offer archive
  emit-consumer-pin.sh         emit ffmpeg-pin.lock
  lib/{common,flags}.sh
docker/Dockerfile.manylinux_2_28
.github/workflows/build.yml
docs/{SIZES.md,LICENSING.md.in}
```

### Building

```bash
# Windows -- inside an MSYS2 MINGW64 shell (not cmd, not PowerShell)
./scripts/build.sh

# Linux x86_64 -- inside manylinux_2_28, NOT on the host
docker build -f docker/Dockerfile.manylinux_2_28 \
  --build-arg MANYLINUX_IMAGE="$(sed -n 's/^MANYLINUX_IMAGE_X86_64=//p' versions.lock)" \
  -t tas-ffmpeg-linux64 .
docker run --rm -v "$PWD:/work" -w /work \
  -e TARGET_ARCH=x86_64 tas-ffmpeg-linux64 ./scripts/build.sh

# Linux aarch64 -- same Dockerfile, aarch64 base image.
# Native on an aarch64 host; on x86_64 you need binfmt/QEMU and it is ~10x slower.
docker build -f docker/Dockerfile.manylinux_2_28 --platform linux/arm64 \
  --build-arg MANYLINUX_IMAGE="$(sed -n 's/^MANYLINUX_IMAGE_AARCH64=//p' versions.lock)" \
  -t tas-ffmpeg-linuxarm64 .
docker run --rm --platform linux/arm64 -v "$PWD:/work" -w /work \
  -e TARGET_ARCH=arm64 tas-ffmpeg-linuxarm64 ./scripts/build.sh

# macOS -- one native build per arch
TARGET_ARCH=arm64  ./scripts/build.sh
TARGET_ARCH=x86_64 ./scripts/build.sh
```

### <a id="verify"></a>What `verify-output.sh` catches

Every check below exists because the failure it catches is otherwise
**silent**: the build succeeds with exit status 0, the archive publishes, and
the breakage lands on a user's machine days later.

The governing idea is that `flags/*.flags` record what we *asked* configure
for, and that is **not** the same as what we got. `--disable-autodetect`, a
missing header, a `pkg-config` that resolved to nothing, a component renamed
between FFmpeg releases — each makes configure quietly hand back less, with a
zero exit status. So every assertion interrogates the **built artefact**.

| # | Assertion | The silent failure it prevents |
|---|---|---|
| 1 | All seven libraries exist, and the real `DT_SONAME` / macOS install-name / Windows filename carries the major from `versions.lock` | nelux hardcodes `avcodec-62.dll` etc. (`FFmpegDelayLoad.cpp:15-21`); a soname bump breaks both consumers at load time |
| 2 | `ffmpeg` and `ffprobe` exist **and execute**, and `ffprobe -print_format json` produces JSON | TAS hard-fails without both (`startup.py:81`) and parses ffprobe JSON in three places. Running them also proves the shared libraries resolve, which a file-existence check does not |
| 3 | `av_version_info()` is exactly `<version>-tas` | Both consumers are told to assert this at startup ([Drift](#drift)). If the build stops producing it, that assertion silently becomes a no-op that passes on *anyone's* FFmpeg |
| 4 | Licence is **GPL v2 or later**, not GPLv3, not LGPL, not nonfree — checked from `ffmpeg -L`, from the `configuration:` line, **and** from `config.h` | A nonfree build is undistributable; a GPLv3 build stops combining with GPLv2-only code; an LGPL build means `--enable-gpl` was lost, i.e. **no x264 and no x265** |
| 5 | **Every line of `flags/required-components.txt` is present in the built binary**, on the platforms it applies to — driven by `ffmpeg -encoders / -decoders / -muxers / -demuxers / -filters / -protocols / -bsfs / -devices` | This is the highest-value check here. It is what turns *"we think the flags are right"* into *"the build proves it"* |
| 6 | Threading is compiled in | See the `--disable-autodetect` trap: the build succeeds and is silently single-threaded |
| 7 | Windows: every `.def` file is present; no DLL/EXE imports a non-system DLL | A missing `.def` breaks nelux's CMake configure; a dynamic `zlib1.dll` / `libx264-*.dll` / `libwinpthread-1.dll` makes the nelux wheel unimportable |
| 8 | Linux: no GLIBC symbol newer than 2.28, **and** every `DT_NEEDED` is inside the manylinux_2_28 policy set | `auditwheel` rejects nelux's *entire* wheel over a single bad reference; a stray `libgnutls.so.30` / `libva.so.2` / `libz.so.1` is the Linux spelling of the same bug as #7 |
| 9 | macOS: every `otool -L` entry is under `/usr/lib`, a system framework, or `@rpath` | Catches a Homebrew build tool leaking into the artefact, which then does not exist on a user's Mac |

Checks 3-5 and 8's `DT_NEEDED` half and 9 are new; the rest were already here.

`required-components.txt` uses **CLI names** (`mov_text`, `libaom-av1`,
`png_pipe`, `dump_extra`) while `flags/*.flags` use **configure names**
(`movtext`, `libaom_av1`, `image_png_pipe`, `dump_extradata`).
`validate-flags.sh` polices the second spelling, `verify-output.sh` the first.
Both are needed, and the mismatch is not academic — `--enable-encoder=mov_text`
is accepted by configure's parser and does nothing.

---

## <a id="encoders-per-platform"></a>Which encoders exist on which platform

Software encoders are identical everywhere. Hardware encoders are not, and
this table is the answer to "what can a cross-platform caller safely default
to?"

| | win64 | linux64 | linuxarm64 | macos-arm64 | macos-x86_64 |
|---|:-:|:-:|:-:|:-:|:-:|
| `libx264`, `libx264rgb`, `libx265`, `libopenh264` | ✅ | ✅ | ✅ | ✅ | ✅ |
| `libsvtav1`, `libaom-av1`, `libvpx-vp9`, `libvpx` | ✅ | ✅ | ✅ | ✅ | ✅ |
| `prores_ks` / `prores` / `prores_aw`, `ffv1`, `png`, `mjpeg`, `gif` | ✅ | ✅ | ✅ | ✅ | ✅ |
| `aac`, `libopus`, `vorbis`, `ac3`, `flac`, `mov_text`, `webvtt` | ✅ | ✅ | ✅ | ✅ | ✅ |
| `h264_nvenc`, `hevc_nvenc`, `av1_nvenc` | ✅ | ✅ | ✅ | ❌ | ❌ |
| `*_cuvid` decoders (all nine) | ✅ | ✅ | ✅ | ❌ | ❌ |
| `h264_qsv`, `hevc_qsv`, `av1_qsv`, `vp9_qsv`, `mpeg2_qsv` | ✅ | ✅ | ❌ | ❌ | ❌ |
| `h264_amf`, `hevc_amf` | ✅ | ✅ | ❌ | ❌ | ❌ |
| `h264_mf`, `hevc_mf` (MediaFoundation) | ✅ | ❌ | ❌ | ❌ | ❌ |
| `h264_videotoolbox`, `hevc_videotoolbox`, `prores_videotoolbox` | ❌ | ❌ | ❌ | ✅ | ✅ |
| `zscale` filter, `libvmaf` filter | ✅ | ✅ | ✅ | ✅ | ✅ |
| `https://` (TLS backend) | ✅ Schannel | ✅ GnuTLS | ✅ GnuTLS | ✅ SecureTransport | ✅ SecureTransport |

**The safe cross-platform H.264 default is `libx264`.** It is the only
hardware-independent H.264 encoder present on all five targets, and it is
first in nelux's probe on macOS and Linux. `libopenh264` is built as a
last-resort fallback (it is the final entry of nelux's probe at
`VideoEncoder.cpp:46,49,51`) but should never be reached in practice.

Machine-readable form of this table: `flags/required-components.txt`, whose
platform selectors are what `verify-output.sh` enforces.

---

## How to bump a version

1. Edit **only** `versions.lock`.
2. `./scripts/fetch-sources.sh` — fails loudly if a tag moved or a hash
   changed.
3. `./scripts/validate-flags.sh` — fails if a new FFmpeg renamed a
   *configure-time* component name.
4. Open a PR. CI runs steps 2-3 on every PR touching `flags/`, `scripts/`,
   `versions.lock` or `docker/`.
5. Tag `vX.Y.Z` to publish. The first build then runs `verify-output.sh`,
   which is where a renamed *CLI* component name surfaces — `validate-flags.sh`
   cannot see those, because the two namespaces are different (see
   [What `verify-output.sh` catches](#verify)).

**When a consumer starts using something new** — a codec string, a container,
a filter, a protocol — add a line to `flags/required-components.txt` with the
`file:line` that proves it. That is the whole review protocol: the flag files
say what we asked for, that file says what must come out, and the build fails
if the two disagree.

Bumping FFmpeg's **major** is different: if a soname changes,
`fetch-sources.sh` aborts before building, because both consumers hardcode
those names (`Nelux/src/Nelux/FFmpegDelayLoad.cpp:15-21`,
`Nelux/tools/ffmpeg.lock:30-31`). Tell both consumers first.

---

## <a id="nvidia-driver-floor"></a>NVIDIA driver floor

`NVCODEC_TAG` in `versions.lock` is a **single editable variable** that sets
the minimum NVIDIA driver version for every NVENC/NVDEC feature in this build:

| nv-codec-headers | min Linux driver | min Windows driver |
|---|---|---|
| `n11.1.5.3` | 470.57.02 | 471.41 |
| **`n12.1.14.0`** (chosen) | **530.41.03** | **531.61** |
| `n13.0.19.0` | 570.0 | 570.0 |

`ffmpeg-8.1.2/configure:7126-7130` accepts, in order of preference:

```
ffnvcodec >= 12.1.14.0                 (unbounded upper -- 13.x also matches)
ffnvcodec >= 12.0.16.1  < 12.1
ffnvcodec >= 11.1.5.3   < 12.0
ffnvcodec >= 11.0.10.3  < 11.1
ffnvcodec >= 8.1.24.15  < 8.2
```

**Why `n12.1.14.0`:** it is the lowest version inside FFmpeg's *preferred*
bracket, so we get every NVENC/NVDEC feature FFmpeg 8.1.2 knows how to use
(including AV1 NVENC, which needs ≥ 12.0 — TAS has three `av1_nvenc` presets),
while keeping the driver floor at 531.61 (March 2023) instead of 570.x
(January 2025). Bumping to `n13.0.19.0` would cut off every user on a
2023-2024 driver in exchange for features neither consumer uses.

The headers are stubs: they `dlopen`/`LoadLibrary` `nvcuda.dll` /
`libnvidia-encode.so` at runtime. **No CUDA toolkit is needed to build, and no
NVIDIA binary is redistributed.** We also skip `--enable-cuda-nvcc`, which is
only needed for the CUDA *filters* (`scale_cuda`, …) — neither consumer uses
one. TAS uses `hwupload_cuda`, and `configure:3518` shows
`hwupload_cuda_filter_deps="ffnvcodec"` only.

---

## <a id="version3"></a>GPL, and why not `--enable-version3`

`--enable-gpl` is deliberate: x264 and x265 are both GPL and both are
required.

`--enable-version3` is deliberately **not** set. Verified against the source,
not assumed: `ffmpeg-8.1.2/configure:2007-2016` defines
`EXTERNAL_LIBRARY_VERSION3_LIST` as exactly

```
gmp libaribb24 liblensfun libopencore_amrnb libopencore_amrwb
libvo_amrwbenc mbedtls rkmpp
```

We enable none of them, so nothing forces version3 on us. `configure:4773`
then reads:

```sh
enabled version3 && { enabled gpl && enable gplv3 || enable lgplv3; }
```

so `--enable-version3` under `--enable-gpl` would relicense the whole binary
as **GPLv3**. Staying off it keeps the output at **GPL-2.0-or-later**, which
is strictly the better position — it stays combinable with GPLv2-only code.
x264's `COPYING` is the plain GPLv2 text and upstream now maintains an explicit
`GPLv2-only` branch, so this is not hypothetical.

One consequence, enforced in the per-OS flag files: **no OpenSSL ≥ 3.0**.
`configure:7493` hard-fails that combination:

```sh
{ enabled gplv3 || ! enabled gpl || enabled nonfree
  || die "ERROR: OpenSSL >=3.0.0 requires --enable-version3"; }
```

`--enable-nonfree` is never used; the output would be undistributable.

## <a id="tls"></a>TLS — every platform, and **not** LibreSSL

| Platform | Backend | Pinned? | `https://` works? |
|---|---|---|---|
| Windows | Schannel (OS) | n/a | yes |
| macOS | SecureTransport (OS) | n/a | yes |
| Linux (both arches) | **GnuTLS**, static, from source | `versions.lock` `GNUTLS_*` + `NETTLE_*` + `GMP_*` | yes |

### Why TLS is required, not optional

`Theanimescripter/src/ytdlp.py:184` and `:202` set

```python
"ffmpeg_location": os.path.dirname(FFMPEGPATH),
```

which points yt-dlp at **our** ffmpeg. TAS sets neither `--downloader` nor
`hls_prefer_native` anywhere (zero hits across all three repos), so yt-dlp's
own defaults apply — and yt-dlp falls back to `FFmpegFD`, spawning our ffmpeg
with an `https://…m3u8` URL, for live and live-from-start formats.
`processUrlInput` (`src/io/inputNormalization.py:19-22`) accepts any
`youtube.com` URL, live streams included.

Without a TLS backend that path fails with *"Protocol not found"* on Linux and
succeeds on Windows/macOS — exactly the per-platform divergence this repo
exists to remove.

### Why **not** LibreSSL

This is the one place where the obvious answer is wrong, so it is worth
spelling out. `ffmpeg-8.1.2/configure:7382-7383`:

```sh
enabled libtls && require_pkg_config libtls libtls tls.h tls_configure &&
    { enabled gpl && ! enabled nonfree &&
      die "ERROR: LibreSSL is incompatible with the gpl"; }
```

**`--enable-libtls` is hard-rejected in any `--enable-gpl` build.** "libtls is
ISC-licensed, therefore GPLv2-compatible" is true of the *licence* and false of
*this configure*. Verified by reading the pinned tarball.

OpenSSL is rejected in both directions (`configure:7493-7494`): ≥ 3.0 demands
`--enable-version3`, < 3.0 is "incompatible with the gpl". mbedtls is in
`EXTERNAL_LIBRARY_VERSION3_LIST` and would force GPLv3.

**GnuTLS is the only remaining option**, and it is clean: `configure:7231`
gates it on nothing but pkg-config, and it is in neither the version3 nor the
nonfree list.

### How it is built

`gmp` → `nettle` → `gnutls`, all **static, from pinned tarballs**, never from
the manylinux image — otherwise `libavformat.so` grows a runtime dependency on
`libgnutls.so.30` that neither consumer ships. GnuTLS is configured
`--with-included-libtasn1 --with-included-unistring --without-p11-kit`, so the
dependency chain stops at those two rather than continuing into the distro.
`verify-output.sh`'s `DT_NEEDED` allowlist (check 8) fails the build if any of
it leaks out dynamically.

GMP and Nettle are each dual LGPLv3+/GPLv2+; **we elect the GPLv2+ arm**, which
keeps the output at GPL-2.0-or-later. Recorded in `docs/LICENSING.md.in`,
because a licence election has nowhere else to live.

> **This is the highest-risk new dependency in the repo.** Three autotools
> builds that have never been run here. If the Linux job fails at
> `build_gnutls`, the minimal back-out is: delete `--enable-gnutls` from
> `flags/ffmpeg.linux.flags`, delete the four `protocol http/https/tls/crypto`
> lines and `demuxer hls` from `flags/required-components.txt`, and accept that
> Linux loses `https://`.

---

## <a id="msvc-import-libraries"></a>Windows: mingw output, MSVC consumption

FFmpeg **cannot** be built with MSVC — it needs C11, GNU inline asm, a POSIX
shell and nasm. It is built with mingw-w64 under MSYS2. The DLLs are still
fully consumable from MSVC, and nelux does exactly that.

nelux does **not** trust the import libs mingw produces. `Nelux/CMakeLists.txt:329-336`
regenerates them:

```cmake
execute_process(
  COMMAND "${CMAKE_AR}" /nologo /machine:${_machine} /def:${_def} /out:${_import_lib})
```

…because FFmpeg's own `doc/platform.texi` warns that dlltool-generated import
libs *"will fail during runtime"* without `/OPT:NOREF`.

**This build emits the `.def` files that path depends on.** Verified against
`ffmpeg-8.1.2/configure`:

- `:6166` `SLIB_CREATE_DEF_CMD` runs `compat/windows/makedef` for every library;
- `:6165` `SLIB_INSTALL_EXTRA_LIB='lib$(SLIBNAME:.dll=.dll.a) $(SLIBNAME_WITH_MAJOR:.dll=.def)'`
  installs both the `.dll.a` **and** the `.def` into `LIBDIR`;
- `:6164` additionally installs a `.lib` into `SHLIBDIR` (which `:6149` sets to
  `bindir` on mingw).

`verify-output.sh` asserts every `.def` is present, because silently losing
them breaks nelux's CMake configure with a confusing error rather than a
useful one.

Nelux's `.def` glob is `"${_c}-*.def"` (`CMakeLists.txt:313`) and its
delay-load regex is
`^(avcodec|avformat|avutil|swscale|swresample|avfilter|avdevice)-.*\.dll$`
(`:620`). Both match our unsuffixed names. **No nelux change is required.**

---

## <a id="linux"></a>Linux: manylinux_2_28, not Ubuntu

nelux publishes `manylinux_2_28` wheels. `auditwheel repair` inspects every
bundled shared object and **rejects the wheel** if a symbol is versioned
against a glibc newer than 2.28. FFmpeg built on `ubuntu-latest` produces
`libavutil.so.60` referencing `GLIBC_2.34`, which fails the repair step for
the **entire wheel**, not just for FFmpeg.

`docker/Dockerfile.manylinux_2_28` is the build environment (AlmaLinux 8 —
glibc 2.28 with a modern devtoolset compiler), and `verify-output.sh` asserts
the glibc floor after every build so this cannot regress unnoticed.

QSV on Linux additionally needs `--enable-vaapi`: the QSV hwcontext creates a
VAAPI *child device* at runtime, so without it `-init_hw_device qsv` fails
even though `h264_qsv` exists. `libva-devel` is installed in the image.

---

## <a id="size"></a>Size

x265 is built as full **multilib (8 + 10 + 12 bit)** and is the single largest
contributor to binary size — roughly **22.7 MB** on Windows, about a fifth of
the whole payload. Dropping to 8-bit only would save ~15 MB and break
`-profile:v main10`, which both consumers use: TAS has `x265_10bit` and
`hevc_nvenc_10bit` presets (`encodingSettings.py:109-123`, `:159-171`) and
nelux's tests cover 10-bit pixel formats. It stays.

Full estimates and their reasoning are in **[docs/SIZES.md](docs/SIZES.md)**.
Every number there is **ESTIMATED** — nothing has been compiled.

---

## <a id="known-gaps"></a>Known gaps

### Closed since the first draft

| Was | Resolution |
|---|---|
| **`h264_mf` is Windows-only but is nelux's default encoder.** | **Fixed on the nelux side, and this repo now backs it.** `VideoEncoder.cpp:38-88` is a runtime *probe*, not a hardcoded name: Windows `h264_mf → libx264 → libopenh264`, macOS `libx264 → h264_videotoolbox → libopenh264`, Linux `libx264 → libopenh264`, throwing at `:83-87` if none resolves. This build guarantees **every** name in every chain on the platform where it can exist — including `libopenh264`, newly pinned, which the probe names but should never reach. See [Which encoders exist on which platform](#encoders-per-platform). |
| **MP3 encoding unavailable.** | **Not a gap — no dependency added, deliberately.** Checked against both consumers rather than assumed. *nelux*: `AV_CODEC_ID_MP3` (`Encoder.cpp:399`) is the 4th entry of a *probe* list, every candidate gated on `avformat_query_codec(...) && avcodec_find_encoder(c)` (`:404-405`), with native AAC first, and the whole list only consulted when `av_guess_codec()` came back empty (`:396`) — which never happens for the five containers `inferContainerFormat()` produces. It degrades cleanly. *TAS*: zero references to `mp3`/`libmp3lame`/`wav`/`flac`/`m4a` under `src/`; the only `-c:a` in the repo is `ffmpegSettings.py:860`, fed by `:846-859` with exactly `{copy, libopus, aac}`. MP3 **decoding** works and is asserted. If `--custom_encoder` ever needs `-c:a libmp3lame`, LAME 3.100's SHA256 is recorded in `flags/ffmpeg.flags` so pinning it is a two-line change. |
| **No `linux/aarch64` target.** | **Added.** `flags/ffmpeg.linux.arm64.flags` (a last-wins delta: no QSV, no VAAPI, no AMF; NVENC/NVDEC/CUVID and GnuTLS kept), `MANYLINUX_IMAGE_AARCH64` in `versions.lock`, the shared Dockerfile parameterised by `TARGETARCH`, a `ubuntu-24.04-arm` CI job, and `LINUXARM64_*` keys in `ffmpeg-pin.lock`. All five targets now build, so nelux can drop its BtbN aarch64 fallback and the "identical builds" guarantee holds everywhere. |
| **No TLS on Linux.** | **Added — GnuTLS, not LibreSSL.** The brief's suggested fix does not work: `configure:7382-7383` ends `--enable-libtls` with `die "ERROR: LibreSSL is incompatible with the gpl"`. See [TLS](#tls) for the evidence that TAS actually reaches an `https://` URL through our ffmpeg (`ytdlp.py:184,202` + yt-dlp's `FFmpegFD` fallback). |

### Still open

| Gap | Impact | Owner |
|---|---|---|
| **nelux writes only 5 containers.** `inferContainerFormat()` (`Encoder.cpp:1509-1524`) maps mp4/mkv/mov/webm/avi and **silently falls back to mp4** for anything else, including `.gif`, `.png` and `.nut`. | Not a build gap — every one of those muxers is present and asserted. It is a nelux behaviour worth knowing: `scripts/bench_end_to_end.py:75` writes `*.nut` with `codec="rawvideo"`, which resolves to the **mp4** muxer and then fails codec/container validation. | nelux. |
| **`--custom_encoder` is unbounded by construction.** | Some flag combinations will name a component we did not build. See [The `--custom_encoder` caveat](#custom-encoder) — this can never be closed by static analysis, only made unlikely. | neither; inherent. |
| **macOS x86_64 has a hard end date: August 2027.** `macos-13` was retired on 2025-12-04 and this repo now builds the Intel leg on `macos-15-intel`. GitHub has stated the `-intel` labels are the **last** x86_64 images and that x86_64 will not be supported on Actions after August 2027 (`actions/runner-images#13045`). | When that date arrives, `macos-x86_64` must either cross-compile from arm64 (**not implemented** — `scripts/build-ffmpeg.sh` has a cross branch but `scripts/build-deps.sh` has no `-DCMAKE_OSX_ARCHITECTURES` and no meson cross files, so deps would be built for the host) or be dropped. `scripts/emit-consumer-pin.sh` already tells consumers to treat a missing platform block as a hard error rather than falling back to an older release. | this repo, before Aug 2027. |
| **Runner labels rot.** A retired macOS label is a **hard job-initialisation failure**, not a fallback, and `fail-fast: false` means the rest of the matrix would still publish a release quietly missing a platform. `macos-14` is already deprecated (fully unsupported 2026-11-02). | Check `runs-on:` against `actions/runner-images` before each release. | this repo, ongoing. |

---

## Licence

The **build scripts in this repository** are **MIT**. They are original work,
not derived from FFmpeg or any GPL dependency — configuring and invoking a
project is not deriving from it. GPL-2.0 section 3 requires "the scripts used
to control compilation" to *accompany* the binaries, not to be licensed GPL;
MIT is GPL-compatible, so they ship verbatim in every corresponding-source
archive and that obligation is met. Same arrangement as BtbN/FFmpeg-Builds.

The **binaries this repository produces** are **GPL-2.0-or-later**, because
x264 and x265 are linked. Every release publishes
`tas-ffmpeg-<version>-corresponding-source.tar.xz` and every binary archive
contains a `licenses/` directory with FFmpeg's `COPYING.GPLv2` /
`COPYING.GPLv3` / `LICENSE.md`, x264's and x265's `COPYING`, and every other
dependency's licence text, plus `LICENSING.md` restating the source offer.

---

## <a id="unverified"></a>What is unverified

**No build has been run.** Not one target, not once. Everything below is
"correct by reading the source" and has not been confirmed by a compiler.
Treat the first CI run as the real review.

### Verified from primary sources (safe to rely on)

- FFmpeg 8.1.2 tarball SHA256 `464beb5e…24c` — **computed locally** from the
  11,710,924-byte file downloaded from ffmpeg.org.
- `n8.1.2` → commit `38b88335f99e76ed89ff3c93f877fdefce736c13`, via the
  annotated tag object `1c2c67c0…`, PGP signature reported valid.
- All seven soname majors, read from `lib*/version_major.h` in that tarball.
- Every configure behaviour cited in this README and in `flags/` — line numbers
  are from the 8.1.2 tarball, read directly.
- **Every flag and component name in `flags/`**, checked against
  `./configure --list-*` from the real 8.1.2 source. This caught `mov_text`
  (the configure name is `movtext`), which configure accepts and silently
  ignores.
- `--disable-autodetect` also disables `THREADS_LIST` — so it silently
  produces a single-threaded FFmpeg unless `--enable-w32threads` /
  `--enable-pthreads` is named. Both are, and `verify-output.sh` asserts it.
- `--disable-postproc` and `--disable-examples` are **not valid options** in
  8.1.2 (libpostproc is gone); `configure` rejects them. Removed.
- `av_version_info()` will be exactly `8.1.2-tas`, from
  `ffbuild/version.sh:40,48`.
- **LibreSSL cannot be used.** `configure:7382-7383` ends `--enable-libtls`
  with `die "ERROR: LibreSSL is incompatible with the gpl"`. Read from the
  tarball. GnuTLS is the only GPL-compatible TLS backend in 8.1.2.
- **Every name in `flags/required-components.txt` is a real CLI name.** All
  171 were checked against `ffmpeg -encoders/-decoders/-muxers/-demuxers/
  -filters/-protocols/-bsfs/-devices` from a real FFmpeg 8.1.2 GPL shared
  build (gyan.dev 8.1.2, the copy at `D:\Nelux\external\ffmpeg`). 167 were
  present; the exceptions were `libopenh264` (that build lacks it — it is the
  reason we now pin it) and three macOS-only VideoToolbox entries that do not
  apply on Windows. That run also caught `dump_extradata` → the CLI name is
  `dump_extra`.
- **`verify-output.sh` itself has been executed** end to end against that same
  real tree. It correctly reported the soname majors, ran both programs,
  rejected the `av_version_info` mismatch, and **detected that gyan's build is
  GPLv3** (it passes `--enable-version3`) — i.e. the licence assertion is not
  theoretical.
- The two manylinux base-image digests were read from quay.io's own API on
  2026-08-04, not guessed.
- The FFmpeg 8.1.2 tarball SHA256 in `versions.lock` was re-verified by
  downloading from ffmpeg.org and hashing: it matches.
- LAME 3.100, GMP 6.3.0, Nettle 3.10.2 and GnuTLS 3.8.10 SHA256s were all
  obtained by downloading and hashing locally on 2026-08-04.

### Not verified — these need a real build

1. **Whether any of it compiles.** No configure run, no `make`, on any target.
2. **The x265 multilib archive merge.** The `ar -M` / `libtool -static` splice
   of `libx265_main{,10,12}.a` is the standard recipe but is untested here; a
   symbol collision or a stale `x265.pc` would only show at FFmpeg link time.
3. **`libvpl` on Windows.** `configure:7309-7317` dies outright if
   `pkg-config vpl >= 2.6` fails, and MSYS2 pkg-config path handling is
   notoriously fragile with Windows-style prefixes. Most likely single point
   of failure in the whole matrix.
4. **`vpl v2023.4.0` actually advertising `vpl >= 2.6`.** Read from the tag
   name, not from a generated `vpl.pc`.
5. **`MFX_CODEC_VP9` under libvpl.** `configure:3672` gates the `vp9_qsv`
   *encoder* on `libmfx MFX_CODEC_VP9`; the libvpl branch enables the internal
   `libmfx` symbol and `configure:7319-7321` then runs the `check_cc`. TAS's
   `qsv_vp9` preset depends on this working. Unconfirmed.
6. **AMF header layout.** `build-deps.sh` copies `amf/public/include` to
   `$PREFIX/include/AMF`; AMF v1.5.2 may have moved it.
7. **The Windows import allowlist actually passing.** mingw links `-lz` against
   `libz.dll.a` by preference. The zlib-from-source step is meant to prevent
   that; whether it wins over any MSYS2 zlib in the search path is untested.
   This is the check that stands between us and an unimportable nelux wheel.
   The same argument now applies to **bzip2, xz/liblzma and libiconv**, which
   are built from pinned source for exactly this reason (`versions.lock`
   `BZIP2_*`/`XZ_*`/`LIBICONV_*`). The mechanism is that `$PREFIX_DIR/lib`
   precedes the toolchain's directories and contains *only* `.a` files, so
   `-lbz2`/`-llzma`/`-liconv` cannot resolve to an import library — sound in
   principle, unexecuted in practice. On Linux the same three used to come
   from the image's `bzip2-devel`/`xz-devel`, which ship only the shared
   library; those packages have been removed from the Dockerfile so a
   regression cannot silently resolve against them.
   Two related unknowns in the same area:
   * **`-DBZ_EXPORT`.** Vanilla `bzlib.h:78-95` declares bzip2's entry points
     as *function pointers* on `_WIN32` without it, which compiles, links,
     and passes `configure`'s `check_lib` — then calls a null pointer at
     runtime. The define is passed both to bzip2's own build and to FFmpeg's
     CFLAGS. Reasoned from the header, not observed.
   * **iconv on Windows.** `--disable-autodetect` forces configure down the
     `libc_iconv` branch (`configure:4727-4731`, `:7838-7842`), which never
     reaches the `-liconv` fallback, so `configure:8285-8287` would `die` on
     mingw. `--extra-libs=-liconv` is passed so the probe's link line picks up
     our static `libiconv.a`. Traced through the pinned `configure`, not run.
8. **The Windows static-runtime story.** `-static-libgcc` and
   `-static-libstdc++` are both passed, but neither is what actually keeps
   `libstdc++-6.dll` out: gcc's `-static-libstdc++` only rewrites the
   *implicit* `-lstdc++` the g++ driver adds, and FFmpeg links with gcc
   against an *explicit* `-lstdc++` from pkg-config. The real mechanism is
   `cxx_runtime_lib()` in `scripts/build-deps.sh`, which writes
   `-l:libstdc++.a` into the generated `.pc` files. `-l:libwinpthread.a` is
   added to `--extra-libs` when the toolchain has that archive. All three are
   backstopped by the import allowlist, but none has been executed.
9. **The glibc ≤ 2.28 assertion passing** inside manylinux_2_28 with SVT-AV1
   and libaom, which use newer pthread/atomic APIs.
10. **macOS cross-arch.** `macos-15` and `macos-15-intel` runners are used
    natively to avoid cross-compiling, but SVT-AV1/libaom/x265 arm64 assembly
    under `MACOSX_DEPLOYMENT_TARGET=11.0` is unconfirmed.
11. **`--install-name-dir=@rpath` + `@loader_path/../lib`** producing
    relocatable dylibs that both a wheel and a CLI can use.
12. **`--disable-autodetect` not over-disabling something.** It is a blunt
    instrument; a feature we assume is on by default may be off.
13. **Every size number in `docs/SIZES.md`.** Extrapolated from BtbN/Debian
    reference points, not measured.
14. **That the resulting binaries behave identically to what the consumers use
    today.** Different configure flags produce different `AVCodecContext`
    defaults, different swscale paths, and different threading behaviour.
    nelux's test suite asserts byte-exactness in several places
    (`tests/test_set_range_identity.py`, `tests/test_batch_color_matrix.py`) —
    those should be run against these binaries before anyone switches over.
15. **The base images are pinned to a dated tag, not a digest.** Both digests
    are recorded in `versions.lock`, but the `FROM` still resolves the tag.
    Switching to `image@digest` would be fully reproducible at the cost of
    breaking when quay.io garbage-collects the manifest.
16. **The GitHub Actions workflow has never run.** Runner labels, the
    `msys2/setup-msys2` package list, and artifact merge behaviour are all
    unexercised. In particular **`ubuntu-24.04-arm`** (the new `linuxarm64`
    job) is assumed available; if this account cannot use it, that job needs
    `ubuntu-latest` + `docker/setup-qemu-action`, which works but is ~10x
    slower.
17. **The GnuTLS stack has never been built here.** gmp → nettle → gnutls is
    three autotools builds inside manylinux_2_28. The `HOGWEED_LIBS` /
    `NETTLE_LIBS` / `GMP_LIBS` overrides in `build-deps.sh` are the standard
    recipe for a static, prefix-local build, but they are unrun. **This is the
    single most likely new build failure**, and [TLS](#tls) documents the
    two-line back-out.
18. **libvmaf and OpenH264 have never been built here either.** libvmaf's
    meson project lives in the repo's `libvmaf/` subdirectory (handled) and
    `-Denable_float=true` is passed explicitly because `float_ssim` needs it
    and that default has moved between 2.x and 3.x. OpenH264 is built via
    meson rather than its hand-written Makefile so that `openh264.pc` is
    generated for `configure:7343`; the meson path is upstream-supported but
    untested here.
19. **aarch64 assembly.** x264, x265, dav1d, libaom, SVT-AV1, libvpx and
    libvmaf all take a different (gas `.S`) assembly path on aarch64 than the
    nasm one they use on x86_64. `--target=arm64-linux-gcc` is passed to
    libvpx explicitly because its autodetect has historically guessed wrong in
    containers; the others rely on their own detection.
20. **`--disable-vaapi` on linux/arm64** is a judgement call, not a measured
    one: VAAPI is enabled on x86_64 solely because the QSV hwcontext needs a
    child device, and QSV is off on aarch64. If an aarch64 user turns out to
    want VAAPI for a non-Intel GPU, that is one line and one `dnf install`.
21. **`ffmpeg -devices` on a build without `lavfi`.** `flags/required-
    components.txt` asserts the `lavfi` indev because nelux's tests generate
    media with `-f lavfi`. That assertion is verified against a real 8.1.2
    build, but the *parser* for `-devices` output has only ever seen one
    build's formatting.
