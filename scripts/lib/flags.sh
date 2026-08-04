#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/lib/flags.sh -- turn flags/*.flags into a configure command line.
# Sourced, never executed.
#
# There is ONE profile. Concatenation order (FFmpeg's configure is LAST-WINS
# for enable/disable, so a later file intentionally overrides an earlier one):
#     flags/ffmpeg.flags
#     flags/ffmpeg.<os>.flags
#     flags/ffmpeg.<os>.<arch>.flags     (optional -- only where an ARCH
#                                         genuinely lacks a feature the OS has)
#
# The third slot exists for exactly one real case today: linux/arm64 has no
# Intel QSV runtime and no AMD AMF runtime, so flags/ffmpeg.linux.arm64.flags
# turns those back off after flags/ffmpeg.linux.flags turned them on. Relying
# on last-wins keeps the x86_64 file readable instead of forcing every line to
# be conditional.
# ---------------------------------------------------------------------------

# flag_files OS [ARCH] -> prints the files that apply, in order, skipping any
# absent. ARCH is optional; omitting it yields only the portable + per-OS
# files, which is what a name-only validation pass wants.
flag_files() {
  local os="$1" arch="${2:-}" f
  for f in "ffmpeg.flags" "ffmpeg.$os.flags" ${arch:+"ffmpeg.$os.$arch.flags"}; do
    [ -f "$REPO_ROOT/flags/$f" ] && printf '%s\n' "$REPO_ROOT/flags/$f"
  done
  return 0
}

# expand_flags OS [ARCH] -> prints one configure flag per line.
# Strips comments and blank lines. Rejects a flag containing whitespace,
# because it would be silently word-split into two broken arguments.
expand_flags() {
  local os="$1" arch="${2:-}" file line
  while IFS= read -r file; do
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line%%#*}"
      line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
      [ -z "$line" ] && continue
      case "$line" in
        --*) ;;
        *) echo "flags.sh: $file: not a configure flag: '$line'" >&2; return 1 ;;
      esac
      case "$line" in
        *[[:space:]]*)
          echo "flags.sh: $file: flag contains whitespace: '$line'" >&2; return 1 ;;
      esac
      printf '%s\n' "$line"
    done < "$file"
  done < <(flag_files "$os" "$arch")
}
