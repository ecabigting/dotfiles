#!/bin/bash
# HDR->SDR path (v3) end-to-end decision test via --dry-run over a real HDR
# file. Asserts: HDR never copy-eligible; tonemap chain present; 8-bit SDR
# yuv420p output; SDR bt709 output tags; system-memory encode path (no pure
# GPU); never hevc_nvenc / never 10-bit output.
set -uo pipefail
V3="${1:-/mnt/FilesSSD/src/dotfiles/ffmpeg/plex_conversion_script_v3.sh}"
FILMS="${2:-/mnt/dorneMedia/Movies/The Creator (2023) (2160p BluRay x265 HEVC 10bit HDR AAC 7.1 Tigole)}"
TMP="/tmp/opencode/hdr-test"
FAILS=0
fail() { echo "FAIL: $*" >&2; FAILS=$((FAILS + 1)); }
ok()   { echo "ok: $*"; }

rm -rf "$TMP"; mkdir -p "$TMP"
D="$TMP/films"; mkdir -p "$D"
for f in "$FILMS"/*.mkv; do [ -e "$f" ] && ln -s "$f" "$D/$(basename "$f")"; done
if [ -z "$(ls "$D"/*.mkv 2>/dev/null | head -1)" ]; then
  echo "FAIL: no source mkv files found under $FILMS" >&2
  exit 1
fi

bash "$V3" --dry-run "$D" > "$TMP/run.log" 2>&1 || true
LOG="$TMP/run.log"

# --- HDR detection + decision -------------------------------------------------
grep -q 'HDR source (smpte2084' "$LOG" && ok "HDR detected with smpte2084 transfer" || fail "HDR detection missing (expected color_transfer smpte2084 in message)"
grep -q 'Needs re-encode' "$LOG" && ok "HDR film forced into re-encode (never copy)" || fail "HDR film was copy-eligible or skipped"

# --- tonemap filter chain -----------------------------------------------------
grep -q 'zscale=t=linear:npl=100' "$LOG" && ok "linearize via zscale (npl=100)" || fail "missing zscale=t=linear:npl=100"
grep -q 'tonemap=hable:desat=0' "$LOG" && ok "tonemap hable curve" || fail "missing tonemap=hable:desat=0"
grep -q "zscale=primaries=bt709:transfer=bt709:m=bt709:r=tv" "$LOG" && ok "re-tag to bt709 primaries+transfer+matrix+range" || fail "missing zscale bt709 retag with m=bt709:r=tv"
grep -q 'format=yuv420p' "$LOG" && ok "explicit 8-bit yuv420p output format" || fail "missing format=yuv420p"

# --- SDR output metadata ------------------------------------------------------
grep -q -- '-colorspace bt709 -color_trc bt709 -color_primaries bt709 -color_range tv' "$LOG" \
  && ok "output tagged SDR bt709" || fail "missing SDR bt709 color tags"

# --- system-memory encode path (never pure GPU for 10-bit HDR) ----------------
grep -q 'Re-encoding via NVENC H.264 (system-memory path' "$LOG" \
  && ok "system-memory 8-bit encode path" || fail "missing NVENC system-memory path log"
if grep -q 'GPU decode+encode, no filter chain' "$LOG"; then
  fail "an HDR film took the no-filter GPU path (filters required)"
else
  ok "all HDR films used the filter-chain path"
fi

# --- output codec invariant: h264 only, no 10-bit, no hevc_nvenc --------------
if grep -q -- '-c:v hevc_nvenc' "$LOG"; then fail "hevc_nvenc still used"; else ok "no hevc_nvenc (universal H.264)"; fi
if grep -q -- 'Executing:.*yuv420p10le' "$LOG"; then fail "10-bit output requested"; else ok "output stays 8-bit"; fi

echo "---"
if [ "$FAILS" -gt 0 ]; then echo "RTL: $FAILS failure(s)" >&2; exit 1; fi
echo "RTL: HDR path checks passed."