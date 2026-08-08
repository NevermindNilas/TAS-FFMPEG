# Handoff

Last updated: 2026-08-08

## Where this stands

`tas-ffmpeg` builds **FFmpeg n8.1.2** from pinned source for five targets, to
replace the third-party builds nelux and TheAnimeScripter currently fetch from
BtbN / gyan.dev / johnvansickle on rolling URLs.

Repo is public at <https://github.com/NevermindNilas/TAS-FFMPEG>. Build system
is MIT; the binaries it produces are GPL-2.0-or-later (see `LICENSE` — the two
things are deliberately separate).

### CI status

**All five legs green**, run 31266899420 on `d863d0f`. Green means the full
pipeline: build, install, every `verify-output.sh` assertion group (the
component contract is now 151-173 entries depending on platform), plus
`package.sh` and licence collection.

The win64 archive from that same commit was also **tested by hand on real
hardware** (RTX 3090 + Intel UHD 770): 84 checks pass. The one red in that
suite is TheAnimeScripter's own invalid `zscale` string, kept in deliberately
as a standing reminder -- see "Open, in the CONSUMERS" below.

### Dependency set as of this release

Added after a three-way audit of nelux, TheAnimeScripter and the two
front-ends (see "What the audits found"): **libmp3lame, libogg + libvorbis,
libwebp**, and the text stack **FreeType -> HarfBuzz -> FriBidi -> libass**.
Removed: **libopenh264**, which no consumer references any more.

None of these is named by consumer source. They are there because the encoder
set is unbounded by construction -- TAS-Standalone's `custom_encoder` is an
unvalidated text field and nelux passes `codec=` straight to
`avcodec_find_encoder_by_name` -- and because three of them closed real holes:
there was NO MP3 encoder on Linux or macOS (Windows had `mp3_mf` only), the
native `vorbis` encoder is experimental-gated, and there was no WebP encoder
at all. Cost: about +3 MB per target, net of dropping libopenh264.

## Two bugs closed since the last handoff

**1. `bin/ffmpeg` segfaulted on `-version` on linux64 while `bin/ffprobe` from
the same build ran.** It was `patchelf`. With no runpath recorded at link time
patchelf has to ADD one, and on a non-PIE `ET_EXEC` that means relocating
`PT_PHDR` and inserting a `PT_LOAD`. It got that right on ffprobe and wrong on
ffmpeg — same tool, same invocation, different section layout. gdb put the
crash in `dl_main` at `rtld.c:1834`, inside the loader's own program-header
walk, before any library initialiser: which is why `LD_BIND_NOW` changed
nothing and why the Implib.so stub was never a plausible suspect.

The fix is `RPATH_PLACEHOLDER` in `scripts/build-ffmpeg.sh`: link with a long
placeholder runpath so patchelf finds a `DT_RUNPATH` big enough to overwrite
IN PLACE and touches no headers at all. It contains no `$`, which is what
makes it safe to pass through `--extra-ldflags` (see the trap below).

**2. libvmaf shipped with NO models on win64 and linux64.** `-lavfi libvmaf`
died on every invocation, including the default one:

    libvmaf WARNING no such built-in model: "vmaf_v0.6.1"
    Error initializing filters

`vmaf/libvmaf/src/meson.build:130` asks for xxd with `required: false`, so on a
host without it the model-embedding step is skipped SILENTLY — meson still
prints `built_in_models: true`, ninja succeeds, configure accepts the library,
and `ffmpeg -filters` lists libvmaf. The CI logs said `Program xxd found: NO`
on exactly the two broken platforms and `YES` on macOS. Nelux's quality gate
(`tests/test_software_encoders.py:181`, raises at `:198`) runs this filter.

Closed at three levels: xxd installed on both hosts, `build_vmaf` dies without
it and checks for the generated `vmaf_v0.6.1.json.c`, and `verify-output.sh`
now RUNS the filter. That last one is the point — the component contract only
ever proved libvmaf was compiled in, and it was: present, listed, unusable.

## How to drive it

```bash
# one leg only (default is all five)
gh workflow run build.yml --ref master -f release=false -f targets=linux64

# everything
gh workflow run build.yml --ref master -f release=false

gh run list --workflow=build.yml --limit 3
gh api repos/NevermindNilas/TAS-FFMPEG/actions/runs/<id>/jobs
```

A run with `targets` set to anything but `all` **cannot publish a release** —
a partial run would emit a `SHA256SUMS` missing four platforms while both
consumers vendor a pin whose other targets do not exist.

## What comes next

1. `v8.1.2` is the first published tag. Pushing a `v*` tag runs the full five
   legs AGAIN and then publishes the archives, `SHA256SUMS`, `ffmpeg-pin.lock`
   and the corresponding-source tarball — so a tag costs a full build, and a
   red leg means no release rather than a partial one.
2. Point `Nelux/tools/ffmpeg.lock` and
   `Theanimescripter/src/infra/getFFMPEG.py` at that release. Note TAS's Linux
   users are currently on FFmpeg **7.0.2 static** (johnvansickle) while nelux
   is on 8.1.2 shared, so on that platform the swap is a major-version AND a
   static-to-shared change, not just a URL.
3. Fix the two runtime-bypass paths in the front-ends (see above), or the pin
   is advisory rather than real.
4. Run both test suites. Windows can be verified on real hardware; Linux and
   macOS integration rests on CI.

## Open, in the CONSUMERS — not in this repo

**TheAnimeScripter's BT.2020 path cannot work with any FFmpeg.**
`src/io/ffmpegSettings.py:797` emits

    zscale=matrix=bt2020:norm=bt2020:dither=error_diffusion,format=yuv420p

`zscale` has no `norm` option at all, and `matrix` has no `bt2020` constant —
it takes `2020_ncl` / `2020_cl` (`bt2020` is a *primaries*/*transfer* value).
FFmpeg fails at filter-graph init, so every render whose source metadata says
BT.2020 dies. Reproduced against this build; it is not a build defect and the
same command fails on a BtbN binary.

**nelux has no default-encoder probe any more.** `VideoEncoder.cpp:58` is
`props.codec = codec.value_or("h264_mf")`, hardcoded and NOT platform-guarded,
so on Linux and macOS a `VideoEncoder(...)` with no explicit `codec=` names an
encoder that cannot exist there. Consequence for this repo, recorded in
`flags/ffmpeg.flags`: `--enable-mediafoundation` is load-bearing on Windows
rather than a first preference. libopenh264, which the deleted probe was the
only thing naming, has now been dropped from the build entirely.

**Both front-ends can bypass the pinned build at runtime.**
`TAS-Standalone/src/main/tas/probe.ts:43-45` checks `PATH` FIRST and only
falls back to the bundled `ffmpeg_shared`, so any system FFmpeg wins.
`TAS-AdobeEdition/src/js/main/utils/youtubeDownloader.ts:235-244` calls
`helpers.downloadFFmpeg()` from `ytdlp-nodejs`, i.e. it downloads a
third-party FFmpeg, and the YouTube transcode/remux paths run on that binary
rather than on ours. Worth fixing before anyone is told the FFmpeg is pinned.

## What the local test covers

`ffmpeg.exe` from the win64 archive, run on real hardware, against the exact
command shapes both consumers issue: every software encoder in the component
contract; all four 10-bit presets (`high10`, `main10`, `p010le`,
`yuv444p10le`); NVENC and QSV encode; `h264_mf`; `hwupload_cuda` + NVENC with
`-init_hw_device cuda=cu:0`; TAS's BT.709 `scale,format,setparams` chain;
`scale='min(1280,iw)':-2`; psnr / ssim / libvmaf; every container both
consumers write; `pipe:1`; all nine cuvid decoders; all nine bitstream
filters; https / tls / crypto; and `ffprobe -print_format json`.

Only `av1_nvenc`, `av1_qsv`, `hevc_mf` and the two AMF encoders are unproven,
for want of the silicon (a 3090 has no AV1 encoder, and there is no AMD GPU in
the machine).

## Traps already paid for — do not re-introduce

- **Do not set the `$ORIGIN` runpath via `--extra-ldflags`.** FFmpeg's
  `configure` implements `add_ldflags` through `append()`, which `eval`s its
  argument, so `$$` becomes configure's PID before make or `sh` are reached.
  Two attempts produced two different silently-wrong runpaths. It is set with
  `patchelf` after `make install` — over a placeholder that IS passed through
  `--extra-ldflags`, which is safe only because it contains no `$`.
- **Do not let patchelf create a runpath from nothing.** See bug 1 above. The
  placeholder must stay at least as long as the real value; `build-ffmpeg.sh`
  asserts it.
- **`CONFIG_VAAPI_DRM` does not exist.** `vaapi_drm` is in `SYSTEM_LIBRARIES`
  (`configure:2565-2571`), which `configure:2662` folds into `HAVE_LIST`, so
  the symbol is `HAVE_VAAPI_DRM`. `vaapi` itself *is* a `CONFIG_` item. Two
  rounds were spent on an assertion that could never pass.
- **A component being present is not the same as it working.** libvmaf proved
  that. If a component needs a runtime asset, assert it by RUNNING it.
- **`require_lock` in `scripts/fetch-sources.sh` is a hand-written list.**
  Removing a pin without removing its entry there fails every run in
  `validate` with "OPENH264_TAG is empty or missing", 20 seconds in. Adding a
  pin without adding it there means the guard silently stops guarding it.
- **`sed -i` must be spelled `sed -i.bak`.** BSD sed (macOS) takes the
  argument after `-i` as a backup SUFFIX, so `sed -i '/x/d' file` there runs
  the FILENAME as the script and dies with "command i expects \\ followed by
  text". Both macOS legs died on this in LAME while Windows and Linux passed.
  Every other `sed -i` in the repo already uses `-i.bak`.
- **CMake 4 rejects `cmake_minimum_required` below 3.5.** libvorbis 1.3.7 —
  still the newest release — declares 2.8.12, so `build_vorbis` passes
  `-DCMAKE_POLICY_VERSION_MINIMUM=3.5`. Check this before pinning any other
  pre-2015 CMake project.
- **Windows needs `core.longpaths` on every fetched tree.** harfbuzz ships
  subsetting fixtures past `MAX_PATH`; `fetch_git` does its own `git init`, so
  `actions/checkout`'s setting does not reach it.
- **Do not grep an installed binary for a build-time string.** A guard that
  looked for a leftover placeholder runpath matched all nine objects, because
  FFmpeg embeds the whole configure line in `.rodata` for `-buildconf`. Read
  the tag with `patchelf --print-rpath` instead. The same lesson cost a second
  round on libvmaf: `xxd -i -n` is only available on vim >= 8.2, so the
  generated symbol NAME differs per platform — check for the generated `.c`.
- **Pin git deps to the peeled commit.** An annotated tag's
  `refs/tags/X` is the tag *object*; a checkout lands on `refs/tags/X^{}`.
  Recording the former made `fetch_git` abort.
- **`versions.lock` is `source`d.** Its value charset is an allowlist and that
  is what makes sourcing it safe. `|` is a control operator at parse time and
  broke a whole round; the mirror separator is `,`.
- **One `if:` per job, and `matrix` is unavailable in a job-level `if:`.**
  Filter the matrix itself — see the `setup` job.
- Scripts are authored on Windows, which has no executable bit. `validate`
  asserts mode 100755 so a new script fails in the cheap gate rather than 40
  minutes into a build.

## Other repos — uncommitted work

None of this is committed. Review before you do.

- **nelux** — `tools/ffmpeg.lock` as the single FFmpeg pin for five consumers,
  pin-stamp so a stale `external/ffmpeg` cannot silently defeat a version
  change, delay-load hook rewritten generation-agnostic (resolves by absolute
  path from the module directory, never crosses a soname major), portable
  default-encoder probe, ~388 MB of stale DLLs removed.
- **TheAnimeScripter** — pinned SHA256-verified FFmpeg download, safe
  extraction, upstream `LICENSE.txt` no longer discarded (it was being stripped
  from every shipped build).
- **TAS-Standalone** — notices on disk, generated Python + npm licence
  roll-ups, proprietary EULA wired into NSIS. Three undisclosed MPL-2.0
  packages surfaced in the engine bundle.
- **TAS-AdobeEdition** — `src/LICENSE.md` no longer asserts AGPL over
  proprietary source, copyleft disclosure across 8 locales with a renderer that
  did not previously exist, false MIT claim deleted.

`D:\TAS-FFMPEG-chassis` is a BtbN-derived alternative chassis, kept as
reference only. Not adopted — Windows cleared the MSYS2 x265 multilib splice,
which was its main justification. Its libva/Implib.so work was ported here.
