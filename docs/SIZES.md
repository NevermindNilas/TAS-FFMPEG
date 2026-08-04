# Size estimates

> **EVERY NUMBER ON THIS PAGE IS ESTIMATED.** Nothing in this repository has
> been compiled. These are extrapolations from published reference builds,
> shown with the arithmetic so a reviewer can disagree with a specific term
> rather than the total. Replace this file with measured numbers after the
> first successful CI run.

Since the design collapsed to a single union build, the size is expected to
land **close to a stock full GPL build**. That is the intended outcome, not a
regression: size is explicitly not being optimised against.

## Reference points

| Build | Uncompressed | Notes |
|---|---|---|
| BtbN `win64-gpl-shared` | **167 MB** (7 DLLs) | `avcodec` alone **98.9 MB**, of which ~80% (~79 MB) is statically-linked external **encoders** |
| Debian 8.1.2, **dynamic** x264/x265 | **50 MB** (7 libs) | so FFmpeg's own code across all seven ≈ 50 MB |
| x264 + x265 static, Windows | **~24.6 MB** | x265 multilib dominates at ~22.7 MB |

The key insight from the BtbN figure: **decoders are cheap, external encoders
are not.** That is why keeping the decoder surface broad costs almost nothing,
and why the savings versus BtbN come entirely from the external libraries we
*do not* link.

## What we link vs what BtbN links

**Linked here:** x264, x265 (multilib), **OpenH264**, SVT-AV1, libaom, dav1d,
libvpx, libopus, libzimg, **libvmaf**, zlib, and on Linux only
**GnuTLS + Nettle + GMP**.

### Added after the coverage audit (not in the original estimate)

| Library | Where | Static size, rough | Why it is here |
|---|---|---|---|
| OpenH264 v2.6.0 | all 5 targets | **~1.0 – 1.5 MB** in `avcodec` | last entry of nelux's default-encoder probe (`VideoEncoder.cpp:46,49,51`) |
| libvmaf v3.2.0 | all 5 targets | **~2 – 4 MB** in `avfilter` (built-in models are the bulk) | `Nelux/tests/test_software_encoders.py:181` raises at `:198` without the filter |
| GnuTLS 3.8.10 + Nettle 3.10.2 + GMP 6.3.0 | **Linux only** | **~4 – 7 MB** in `avformat` | the only GPL-compatible TLS backend; see README#tls |

So Linux gains roughly **7 – 12 MB** over the original estimate and the other
targets roughly **3 – 5 MB**. Both are inside the existing ranges' error bars,
which is another way of saying: these numbers are still estimates.

**In BtbN but not here:** libass + freetype + fontconfig + harfbuzz + fribidi,
libbluray, libsrt, librist, libzmq, libmp3lame, libtwolame,
libtheora, libvorbis, libspeex, libgsm, libilbc, libsoxr, libssh, libopenmpt,
libmodplug, libgme, libshine, libsnappy, libxml2, libplacebo + vulkan +
glslang, chromaprint, frei0r, libvidstab, librubberband, avisynth, libjxl,
libwebp, libopenjpeg, libxvid, libdavs2, libxavs2, libuavs3d, libkvazaar,
librav1e, libzvbi, libaribb24.

That list is the ~60 MB difference below.

## Per-library estimate — Windows x64 (uncompressed, stripped)

| Artefact | Estimate | Reasoning |
|---|---|---|
| `avcodec-62.dll` | **70 – 85 MB** | FFmpeg's own avcodec ≈ 25 MB (Debian-derived) + x264 ~2.5 + **x265 multilib ~22.7** + SVT-AV1 ~11 + libaom ~9 + dav1d ~2 + libvpx ~5 + opus ~1 |
| `avformat-62.dll` | 10 – 14 MB | all demuxers/muxers retained |
| `avfilter-11.dll` | 5 – 8 MB | all filters + libzimg ~1.5 MB |
| `avutil-60.dll` | 2 – 4 MB | |
| `swscale-9.dll` | 1 – 2 MB | |
| `avdevice-62.dll` | 0.4 – 0.8 MB | dshow/gdigrab only |
| `swresample-6.dll` | 0.3 – 0.6 MB | |
| `ffmpeg.exe` + `ffprobe.exe` | 1.5 – 3 MB | linked against the shared libs, so thin |
| **Total** | **~90 – 115 MB** | central estimate **~105 MB**; **~40 – 45 MB** zipped |

Versus BtbN's 167 MB, that is roughly a **35 – 45 % reduction**, entirely from
the omitted external libraries.

## Per-platform

| Target | Uncompressed | Compressed | Confidence |
|---|---|---|---|
| Windows x64 (`.zip`) | **~105 MB** | ~42 MB | **Medium** — directly anchored to BtbN, same toolchain family, same static-dep strategy |
| Linux x86_64 (`.tar.xz`) | **~90 MB** | ~30 MB | **Low-medium** — ELF is typically 10–15 % smaller than PE for the same code, but manylinux's devtoolset and `-fPIC` push the other way |
| macOS arm64 (`.tar.xz`) | **~70 MB** | ~25 MB | **Low** — x265/libaom/SVT-AV1 ship far less NEON assembly than x86 assembly, so the codec blobs shrink substantially. This is the number I would least trust |
| macOS x86_64 (`.tar.xz`) | **~90 MB** | ~32 MB | **Low-medium** — same code as Linux, Mach-O overhead |

## The x265 decision

x265 multilib (8 + 10 + 12 bit) is **~22.7 MB on Windows** — about a fifth of
the entire payload and the single largest line item.

**It stays**, because both consumers need >8-bit:

- TAS: `x265_10bit` (`encodingSettings.py:109-123`) and `hevc_nvenc_10bit`
  (`:159-171`) presets, plus `hevc_amf_10bit` (`:249-263`) and
  `qsv_h265_10bit` (`:180-192`);
- nelux: 10-bit pixel formats across the test suite, and `-profile:v main10`
  paths.

An 8-bit-only x265 would save roughly **15 MB** and break every one of those
presets with `-profile:v main10` unsupported. Not worth it.

## If size ever does become a problem

In descending order of return, and each with a real cost:

1. **Drop libaom** (~9 MB). SVT-AV1 covers AV1 encoding and dav1d covers AV1
   decoding. Cost: nelux's AV1 decoder chain (`Decoder.cpp:151`,
   `{"libdav1d","libaom-av1","av1"}`) loses its middle entry, and the
   `libaom-av1` encoder disappears from nelux's test matrix.
2. **8-bit-only x265** (~15 MB). Cost: breaks four TAS presets. See above.
3. **`--disable-encoders` + an explicit allowlist** (~5–10 MB). Cost: directly
   contradicts the union rule and the unbounded `--custom_encoder` surface.
4. **`--enable-small`** (~5–8 %). Cost: measurable decode/encode slowdown; a
   bad trade for two throughput-sensitive consumers.
5. **LTO.** Unmeasured, and a known source of miscompiles against FFmpeg's
   hand-written assembly. Measure before believing.
