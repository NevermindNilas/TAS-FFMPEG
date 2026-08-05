# Handoff

Last updated: 2026-08-06

## Where this stands

`tas-ffmpeg` builds **FFmpeg n8.1.2** from pinned source for five targets, to
replace the third-party builds nelux and TheAnimeScripter currently fetch from
BtbN / gyan.dev / johnvansickle on rolling URLs.

Repo is public at <https://github.com/NevermindNilas/TAS-FFMPEG>. Build system
is MIT; the binaries it produces are GPL-2.0-or-later (see `LICENSE` — the two
things are deliberately separate).

### CI status

**All five legs green**, run 31050045541 on `01d424b`. Green means the full
pipeline: build, install, every `verify-output.sh` assertion group (including
the 171-entry component contract in `flags/required-components.txt`), plus
`package.sh` and licence collection.

The win64 archive from that run was also **tested by hand on real hardware**
(RTX 3090 + Intel UHD 770): 80 checks pass, covering every encoder, filter,
muxer, protocol and bitstream filter either consumer invokes. See "What the
local test covers" below.

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

1. Tag `v*` so the release job publishes the archives, `SHA256SUMS`,
   `ffmpeg-pin.lock` and the corresponding-source tarball.
2. Point `Nelux/tools/ffmpeg.lock` and
   `Theanimescripter/src/infra/getFFMPEG.py` at that release.
3. Run both test suites. Windows can be verified on real hardware; Linux and
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
encoder that cannot exist there. Consequences for this repo are recorded in
`flags/ffmpeg.flags`: `--enable-mediafoundation` is load-bearing on Windows
rather than a first preference, and `--enable-libopenh264` is now kept on the
union rule alone (zero references to openh264 in any of the four repos). To
drop it, remove the flag, `OPENH264_*` in `versions.lock`, `build_openh264` in
`scripts/build-deps.sh` and the `encoder libopenh264` line in
`flags/required-components.txt` together.

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
