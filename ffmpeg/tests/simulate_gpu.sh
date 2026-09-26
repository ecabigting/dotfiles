#!/bin/bash
# Verify v3's GPU decisions by DRY-RUNNING it over randomly sampled real
# library files. Never runs a conversion (the script's --dry-run mode only
# prints the encoder matrix + per-file decisions + the assembled command).
set -euo pipefail
V3="${1:-}"; WORK="${2:-}"; ROOT="${3:-}"; COUNT="${4:-10}"
if [ -z "$V3" ] || [ -z "$WORK" ] || [ -z "$ROOT" ]; then
  echo "usage: $0 /path/to/plex_conversion_script_v3.sh /path/to/work /path/to/library [count]" >&2
  exit 2
fi
FAILS=0
fail() { echo "FAIL: $*" >&2; FAILS=$((FAILS + 1)); }
ok()   { echo "ok: $*"; }

SAMPLE="$WORK/sample"
rm -rf "$SAMPLE"
mkdir -p "$SAMPLE"

mapfile -t FILES < <(find "$ROOT" \( -name converted -o -name incomplete \) -prune -o -type f -name '*.mkv' -print)
if [ "${#FILES[@]}" -eq 0 ]; then
  echo "FAIL: no .mkv files found under $ROOT" >&2
  exit 1
fi
N=${#FILES[@]}
c=$(( COUNT < N ? COUNT : N ))
idx=$(awk -v n="$N" -v c="$c" 'BEGIN{srand(2026); for(i=0;i<c;i++){r=int(rand()*n); while(seen[r]++) r=int(rand()*n); if(sep)printf " "; printf "%d", r; sep=1}}')
i=0
for k in $idx; do
  i=$((i + 1))
  base=$(basename "${FILES[$k]}")
  ln -sf "${FILES[$k]}" "$SAMPLE/$(printf '%02d - %s' "$i" "$base")"
done
echo "sampled ${i} files of ${N} under $ROOT"

bash "$V3" --dry-run "$SAMPLE" > "$WORK/run.log" 2>&1

# 1. startup encoder matrix + GPU selection
grep -q '\[ENCODER\]' "$WORK/run.log" && ok "startup encoder matrix printed" || fail "missing [ENCODER] line"
grep -q 'GPU H.264 encoding selected' "$WORK/run.log" && ok "GPU H.264 selected" || fail "GPU H.264 NOT selected (see log)"

# 2. every re-encode decision must be NVENC H.264 (GPU); zero CPU fallbacks
REENC=$(grep -c 'Needs re-encode' "$WORK/run.log" || true)
NVENC=$(grep -c 'Re-encoding via NVENC H.264' "$WORK/run.log" || true)
CPU=$(grep -c 'CPU libx264' "$WORK/run.log" || true)
if [ "$REENC" -eq 0 ]; then
  fail "no re-encode decisions in the sample; the GPU checks are vacuous (grow the sample or point at another root)"
else
  ok "sample produced $REENC re-encode decision(s)"
fi
grep -q 'h264_nvenc' "$WORK/run.log" && ok "assembled commands reference h264_nvenc" || fail "no h264_nvenc in any command"
if [ "$NVENC" -eq "$REENC" ]; then ok "GPU used for $NVENC/$REENC re-encode decisions"; else fail "GPU used for $NVENC/$REENC re-encode decisions"; fi
[ "$CPU" -eq 0 ] && ok "zero CPU re-encode decisions" || fail "$CPU CPU re-encode decision(s) (warnings require failsafe path)"

# 3. no libx264 fallback in any decision
if grep -q 'h264_nvenc unavailable' "$WORK/run.log"; then
  fail "libx264 fallback used in a decision (see log)"
else
  ok "no libx264 decision"
fi

# 4. dry-run wrote nothing: the find-controlled sample dir must not have produced
#    output mkv files (no conversion ran)
OUTS=$(find "$SAMPLE" -name '*.mkv' | wc -l)
[ "$OUTS" -eq "$i" ] && ok "dry-run produced no output files (only $i symlinks present)" || fail "expected $i symlinks, found $OUTS files (a conversion may have run)"

echo "---"
echo "Re-encode decisions: $REENC | NVENC: $NVENC | CPU-libx: $CPU"
if [ "$FAILS" -gt 0 ]; then echo "RTL: $FAILS failure(s)" >&2; exit 1; fi
echo "RTL: all GPU checks passed."