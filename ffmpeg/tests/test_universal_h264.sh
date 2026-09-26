#!/bin/bash
# Universal H.264 output decision test (v3, post-2026-09-26): HEVC 10-bit S1
# must re-encode to 8-bit H.264 via the system-memory path; h264 8-bit SDR
# must still copy; an 8-bit VP8 clip must re-encode via the pure-GPU path;
# never 10-bit output. Covers all three re-encode routing branches.
set -uo pipefail
V3="${1:-/mnt/FilesSSD/src/dotfiles/ffmpeg/plex_conversion_script_v3.sh}"
TMP="/tmp/opencode/universal-test"
FAILS=0
fail() { echo "FAIL: $*" >&2; FAILS=$((FAILS + 1)); }
ok()   { echo "ok: $*"; }

rm -rf "$TMP"; mkdir -p "$TMP/D"
# HEVC Main10 Hells Paradise (must sysmem-reencode) + h264 8-bit Sentenced (must copy).
HP=0
for f in /mnt/dorneMedia/Anime/Hells\ Paradise/Season\ 1/Jigokuraku*.mkv; do [ -e "$f" ] && { ln -sf "$f" "$TMP/D/HP $(basename "$f")"; HP=$((HP + 1)); }; done
for f in /mnt/dorneMedia/Anime/Sentenced\ to\ Be\ a\ Hero/Season\ 1/Sentenced*.mkv; do [ -e "$f" ] && ln -sf "$f" "$TMP/D/SB $(basename "$f")"; done
# Synthetic 8-bit yuv420p VP8 clip (must re-encode via the pure-GPU branch).
ffmpeg -nostdin -hide_banner -v error -y -f lavfi -i testsrc=duration=2:size=320x240:rate=25 \
  -c:v vp8 -pix_fmt yuv420p "$TMP/D/VP8 sample.mkv" 2>/dev/null \
  || { echo "FAIL: could not synthesize the VP8 clip" >&2; exit 1; }
[ -n "$(ls "$TMP/D"/*.mkv 2>/dev/null | head -1)" ] || { echo "FAIL: no source mkv files found" >&2; exit 1; }

bash "$V3" --dry-run "$TMP/D" > "$TMP/run.log" 2>&1 || true
LOG="$TMP/run.log"

# HEVC 10-bit must NOT be copy-eligible and must re-encode via system-memory path
grep -q 'Needs re-encode' "$LOG" && ok "HEVC S1 forced to re-encode" || fail "HEVC was copy-eligible"
if grep -q 'Proven-compatible (hevc' "$LOG"; then fail "an HEVC stream was copied (must re-encode)"; else ok "no HEVC copy (only h264 8-bit SDR may copy)"; fi
grep -q -- 'Executing:.*-c:v h264_nvenc' "$LOG" && ok "h264_nvenc used" || fail "hevc_nvenc still used"
grep -q -- 'Executing:.*-profile:v high' "$LOG" && ok "High profile" || fail "no High profile"
if grep -q -- 'Executing:.*yuv420p10le' "$LOG"; then fail "10-bit output requested"; else ok "8-bit yuv420p output only"; fi

# per-codec routing: every HP 10-bit file on sysmem (never pure-GPU); the VP8
# 8-bit clip on pure-GPU (never sysmem); Sentenced copied.
SYS=$(grep -c 'Re-encoding via NVENC H.264 (system-memory path' "$LOG" || true)
PURE=$(grep -c 'GPU decode+encode, no filter chain' "$LOG" || true)
COPY=$(grep -c 'Proven-compatible (h264' "$LOG" || true)
[ "$SYS" -ge "$HP" ] && ok "all $HP HEVC 10-bit files on the system-memory path (got $SYS)" || fail "expected >=$HP sysmem decisions, got $SYS"
[ "$PURE" -eq 1 ] && ok "VP8 clip took the pure-GPU path (got $PURE)" || fail "expected 1 pure-GPU decision, got $PURE"
[ "$COPY" -ge 1 ] && ok "h264 8-bit SDR sources still copy (got $COPY)" || fail "h264 8-bit copy rule broken"

echo "---"
if [ "$FAILS" -gt 0 ]; then echo "RTL: $FAILS failure(s)" >&2; exit 1; fi
echo "RTL: universal H.264 checks passed."