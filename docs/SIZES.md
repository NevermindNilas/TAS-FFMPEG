# Sizes

**Measured**, not estimated. Every number below comes from the artefacts of CI
run 31266899420 (commit `d863d0f`, FFmpeg 8.1.2), unpacked and measured file by
file. The previous version of this page was a set of pre-build estimates and
asked to be replaced with real numbers; this is that replacement.

Counting rule: only the REAL versioned files are counted. Each library ships
with two symlinks beside it (`libavcodec.so.62` and `libavcodec.so` point at
`libavcodec.so.62.28.102`), and a naive `du` on a filesystem without symlinks —
Windows, for instance — triples the total.

## Per target, uncompressed

| Library | win64 | linux64 | linuxarm64 | macos-arm64 | macos-x86_64 |
|---|---:|---:|---:|---:|---:|
| avcodec | 68.08 | 60.84 | 39.73 | 36.11 | 57.12 |
| avfilter | 12.61 | 10.79 | 8.42 | 7.31 | 8.91 |
| avformat | 3.72 | 5.53 | 5.39 | 2.49 | 2.42 |
| avutil | 2.45 | 1.44 | 0.94 | 0.71 | 0.79 |
| swscale | 1.93 | 1.91 | 1.25 | 1.11 | 1.40 |
| swresample | 0.17 | 0.14 | 0.19 | 0.11 | 0.13 |
| avdevice | 0.15 | 0.06 | 0.19 | 0.07 | 0.04 |
| **seven libraries** | **89.12** | **80.70** | **56.11** | **47.92** | **70.80** |
| `ffmpeg` | 0.49 | 0.43 | 0.51 | 0.43 | 0.41 |
| `ffprobe` | 0.21 | 0.18 | 0.25 | 0.21 | 0.17 |
| **archive** (zip / tar.xz) | **33.1** | **21.3** | **18.7** | **39.6** | **49.5** |

### What the safety-net libraries cost

Against the previous measurement (run 31050045541, before libmp3lame,
libvorbis, libwebp and the libass text stack went in, and before libopenh264
came out):

| | win64 | linux64 | linuxarm64 | macos-arm64 | macos-x86_64 |
|---|---:|---:|---:|---:|---:|
| seven libraries, before | 84.95 | 77.32 | 53.16 | 45.41 | 67.95 |
| seven libraries, now | 89.12 | 80.70 | 56.11 | 47.92 | 70.80 |
| **delta** | **+4.2** | **+3.4** | **+3.0** | **+2.5** | **+2.9** |

Roughly **+3 MB**, net of the ~1 MB libopenh264 removal. It lands in two
places: `avcodec` takes libmp3lame + libvorbis + libwebp, and `avfilter`
takes libass + FreeType + HarfBuzz + FriBidi (about +3 MB there alone, which
is the single largest line). The compressed archives grow ~2 MB each.

For scale: `avfilter` is still 12.61 MB against a full build's 118.58 MB.

The two CLI programs are ~0.5 MB because they link against the shared
libraries. That is the whole point of shipping shared: nelux bundles the seven
libraries in its wheel and delay-loads them, and TAS spawns `bin/ffmpeg` out of
the same tree, so the code exists once rather than once per consumer.

aarch64 is the smallest by a wide margin — no NVENC/QSV/AMF encoders exist for
it and there is no x86 hand-written assembly to carry.

## Against the official builds

Measured on the same machine, against the gyan.dev full build 8.1.2 that nelux
currently vendors in `external/ffmpeg`:

| Library | ours | gyan full 8.1.2 | difference |
|---|---:|---:|---|
| avcodec | 68.08 | 92.94 | −24.9 |
| avfilter | 12.61 | 118.58 | **−106.0** |
| avformat | 3.72 | 19.25 | −15.5 |
| avdevice | 0.15 | 6.03 | −5.9 |
| avutil | 2.45 | 3.00 | −0.6 |
| swscale | 1.93 | 12.16 | −10.2 |
| swresample | 0.17 | 0.46 | −0.3 |
| **total** | **89.12** | **252.4** | **−65%** |

`ffmpeg.exe` itself: 0.49 MB vs 0.60 MB. Both are shared builds, so neither
number means much on its own.

Where the difference actually is:

* **avfilter, −106 MB.** This is the entire story, and it is not FFmpeg's own
  filter code. It is libplacebo + vulkan + glslang, frei0r, libvidstab,
  librubberband and OpenCL. No consumer references any of them.
  We now carry libass + FreeType + HarfBuzz + FriBidi ourselves — that is the
  ~3 MB avfilter grew by — so `subtitles=`, `ass` and `drawtext` work here
  too. The remaining gap is almost entirely libplacebo/vulkan/glslang.
  fontconfig is still excluded; see `versions.lock`.
* **avcodec, −25 MB.** We link x264, x265, SVT-AV1, libaom, dav1d, libvpx,
  opus, LAME, libvorbis and libwebp. gyan additionally links libxvid,
  librav1e, libjxl, libopenjpeg, libtheora, libtwolame, libspeex, libgsm,
  libilbc, libshine, libcodec2, libopencore-amr, davs2, xavs2, uavs3d,
  xeve/xevd, vvenc, oapv and more.
* **avformat, −15.5 MB.** libsrt, librist, libssh, libzmq, libxml2, libbluray,
  libcdio.
* **avdevice, −5.9 MB.** caca, OpenAL, libcdio. We still ship every device the
  consumers can reach: `dshow`, `gdigrab`, `lavfi` and `vfwcap` all fit in
  0.15 MB.
* **swscale, −10.2 MB.** Note this one is against nelux's vendored copy, which
  is not stock — the repo has `libswscale_lean` experiments. TAS's stock gyan
  8.0.1 `swscale-9.dll` is 1.83 MB against our 1.93 MB, which is the honest
  comparison.

Nothing here was optimised for size. The difference is entirely a consequence
of linking what the consumers actually use, which is the same audit recorded in
`flags/ffmpeg.flags`.

## What size did NOT buy

Decoders and demuxers were never trimmed and never will be: `Nelux/README.md`
promises "anything libavcodec can decode" and TAS accepts arbitrary user media.
The decoder surface is cheap — the numbers above are the evidence. Every
megabyte of the difference above is an ENCODER or a filter dependency.
