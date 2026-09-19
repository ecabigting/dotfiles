#!/bin/bash
# HDR->SDR path (v3) end-to-end decision test via --dry-run over the two
# Thunderbolt films. Asserts: HDR never copy-eligible; tonemap chain present;
# SDR bt709 output tags; PGS muxed soft (never burned). Fails on current code.
set -uo pipefail
V3="${1:-/mnt/FilesSSD/src/dotfiles/ffmpeg/plex_conversion_script_v3.sh}"
FILMS="${2:-/mnt/dorneMedia/Pinoy/UC Gundam/Mobile Suit Gundam Thunderbolt}"
TMP="/tmp/opencode/hdr-test"
FAILS=0
fail() { echo "FAIL: $*" >&2; FAILS=$((FAILS + 1)); }
ok()   { echo "ok: $*"; }

rm -rf "$TMP"; mkdir -p "$TMP"
# dry-run over the films dir (create symlink scan dir with only the films)
D="$TMP/films"; mkdir -p "$D"
for f in "$FILMS"/*.mkv; do ln -s "$f" "$D/$(basename "$f")"; done

bash "$V3" --dry-run "$D" > "$TMP/run.log" 2>&1 || true
LOG="$TMP/run.log"

# --- HDR detection + decision -------------------------------------------------
grep -q 'HDR (smpte2084' "$LOG" && ok "HDR detected with smpte2084 transfer" || fail "HDR detection missing (expected color_transfer smpte2084 in message)"
grep -q 'Needs re-encode' "$LOG" && ok "HDR films forced into re-encode (never copy)" || fail "HDR film was copy-eligible or skipped"

# --- tonemap filter chain -----------------------------------------------------
grep -q 'zscale=t=linear:npl=100' "$LOG" && ok "linearize via zscale (npl=100)" || fail "missing zscale=t=linear:npl=100"
grep -q 'tonemap=hable:desat=0' "$LOG" && ok "tonemap hable curve" || fail "missing tonemap=hable:desat=0"
grep -q "zscale=primaries=bt709:transfer=bt709" "$LOG" && ok "re-tag to bt709 primaries+transfer" || fail "missing zscale bt709 retag"
grep -q 'format=yuv420p10le' "$LOG" && ok "explicit 10-bit yuv420p output format" || fail "missing format=yuv420p10le"

# --- SDR output metadata ------------------------------------------------------
grep -q -- '-colorspace bt709 -color_trc bt709 -color_primaries bt709 -color_range tv' "$LOG" \
  && ok "output tagged SDR bt709" || fail "missing SDR bt709 color tags"

# --- PGS soft-mux (never burned) ----------------------------------------------
grep -q 'Muxing.*image-based' "$LOG" && ok "image sub logged as soft mux" || fail "no soft-mux subtitle log line"
if grep -q -- "subtitles='" "$LOG"; then
  fail "subtitles burn filter present (libass cannot render PGS)"
else
  ok "no subtitles burn filter"
fi
grep -q -- '-map 0:4 -c:s copy -metadata:s:s:0 language=eng' "$LOG" \
  && ok "eng PGS stream 4 mapped as soft copy" || fail "missing soft PGS -map/-c:s copy"

# --- sanity: no HDR file got a pure-GPU path or remained HDR ------------------
if grep -q 'GPU decode+encode, no filter chain' "$LOG"; then
  fail "an HDR film took the no-filter GPU path (filters required)"
else
  ok "all HDR films used the filter-chain path"
fi

echo "---"
if [ "$FAILS" -gt 0 ]; then echo "RTL: $FAILS failure(s)" >&2; exit 1; fi
echo "RTL: HDR path checks passed."