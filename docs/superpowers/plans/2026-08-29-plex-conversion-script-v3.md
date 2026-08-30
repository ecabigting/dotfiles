# Plex Conversion Script v3 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rewrite `ffmpeg/plex_conversion_script_v2.sh` as `ffmpeg/plex_conversion_script_v3.sh` that copies every stream that is at-or-below the proven TV target spec and normalizes only what exceeds it, so the user's Samsung TV always direct-plays Plex without transcoding.

**Architecture:** Keep the v2 batch scaffolding (CLI, dependency check, NVENC detection, `find` loop, `converted/` output, skip-existing, per-file timing). Replace the three stream-logic sections with a single-file decision engine that probes once via `ffprobe`/`jq`, decides per-stream copy vs. normalize against the locked ceiling, and assembles one ffmpeg command. Subtitle handling stays embedded (muxed) subrip, with English image subtitles burned into the video. A bash test harness (`tests/`) builds synthetic fixtures with ffmpeg and asserts output streams with `ffprobe`/`jq`.

**Tech Stack:** bash 5 (with `set -euo pipefail`), ffmpeg, ffprobe (libavformat/libavcodec), jq, `awk` (fps math), `sed` (filter-path escaping). Test fixtures: ffmpeg synthetic encoders (`libx264`, `mpeg2video`, `aac`, `ac3`, `subrip`, `ass`, `hdmv_pgs_subtitle`).

**Spec:** Locked requirements agreed with the user during brainstorming (records below). The plan argues from the approved design recorded in "Spec & Approved Design".

---

## Global Constraints

Copy/verbatim from the approved design — every task's requirements implicitly include these:

1. **Two empirically proven target files on the user's TV (both played with zero transcode):**
   - Crushology sample: H.264 High / `yuv420p` / 1080p / 30fps; AAC-LC stereo 48kHz; subrip subs embedded; mjpeg cover art.
   - Kaiju No. 8 sample: **HEVC Main 10 / `yuv420p10le` / 1080p / 23.81fps**; AAC-LC stereo **48kHz and 44.1kHz**; chapters; no subs.
2. **Video copy bar (ceiling, copy-eligible):** copy the first real video stream iff
   - `codec_name == "h264"` AND `pix_fmt == "yuv420p"`, OR
   - `codec_name == "hevc"` AND `pix_fmt ∈ { "yuv420p", "yuv420p10le" }`,
   AND `width ≤ 1920` AND `height ≤ 1088` AND integer fps (`avg_frame_rate` numerator/denominator) `≤ 30`, AND no pending subtitle burn.
   Anything else (4K, >30 fps, H.264 10-bit Hi10P, HEVC 12-bit, AV1/VP9/MPEG2/VC-1, odd pix_fmts) → re-encode.
3. **Video normalize target:** HEVC Main 10 / `yuv420p10le`, fit within 1920x1080 (even dims, `setsar=1`), fps capped at 30. Encoder choice:
   - Filter chain required (resize, fps cap, or subtitle burn) → **CPU** `libx265 -preset medium -crf 22 -pix_fmt yuv420p10le -vf <chain>` (fallback `libx264 -preset medium -crf 19 -pix_fmt yuv420p` if `libx265` is unavailable). `HWACCEL` must be empty on this path (filters can't run on CUDA frames).
   - No filter chain → **NVENC** `hevc_nvenc -preset p7 -tune hq -cq 27 -rc vbr -multipass 1 -b_ref_mode middle -bf 4 -spatial-aq 1 -temporal-aq 1 -rc-lookahead 32 -pix_fmt yuv420p10le` with `HWACCEL="-hwaccel cuda -hwaccel_output_format cuda"` when `hevc_nvenc` is available, else CPU `libx265` per above.
4. **Audio selection:** keep audio streams with language `kor|ko` , `jpn|ja`, `eng|en` only, priority order KOR → JPN → ENG, and within a language by original index. If none match, fallback to the first audio stream (any language) and force the stereo-AAC encode. All other audio streams are dropped.
5. **Audio copy bar:** copy a kept stream iff `codec_name == "aac"` AND `channels == 2`. **Sample rate AND bitrate are irrelevant** — 44.1k/48k proven, and aac stereo at 128k/192k/320k all copy as-is (user approved "aac && stereo → copy no matter the size"). Mono (1ch) and >2ch (5.1/7.1) and non-aac (ac3/eac3/dts/flac/opus/vorbis/truehd) → re-encode to `aac -b:a 192k -ac 2 -ar 48000` (ffmpeg's built-in downmix). The 192k figure is only the re-encode output bitrate, never a copy threshold.
6. **Subtitle policy (English-only, one track):** find the **largest English** (`eng|en`) subtitle stream by size: `tags.NUMBER_OF_BYTES` → else `BPS × DURATION(seconds)` → **else `DURATION(seconds)` alone when `BPS` is missing** (fix for stats-less mkvmerge files like Unicorn Re0096 — a Full track still outranks a Signs/opening track by duration) → else `bit_rate × duration` → else `0`. If it is text-based → mux embedded as subrip (`-c:s copy` if already `subrip`, else `-c:s subrip`). If image-based (`hdmv_pgs_subtitle | dvd_subtitle | dvb_subtitle | xsub`) → **burn** into the video via the `subtitles` filter (forces CPU re-encode; track is not muxed). **Every other subtitle stream is dropped.** If there is NO English subtitle → no subtitle tracks, no burn.
7. **Preserve (but NOT attachments):** chapters (`-map_chapters 0`) and format-level metadata (`-map_metadata 0`) are preserved. **Cover art and font attachments are intentionally dropped** (user decision, 2026-08-29): fonts are never needed because text subs are converted to subrip (no styling/font references survive) and image subs are burned as bitmaps; Plex supplies its own poster from the video.
8. **Filename cleanup:** When deriving the output name, strip every balanced `[...]` group (brackets AND their entire contents) and every balanced `(...)` group (parentheses AND their entire contents) from the input basename, then collapse runs of whitespace to a single space and trim leading/trailing whitespace; the output always keeps the `.mkv` extension. Examples: `[Sokudo] Jujutsu Kaisen - S01E01 v2 [1080p BD AV1][Dual Audio].mkv` → `Jujutsu Kaisen - S01E01 v2.mkv`; `[Purple] JUJUTSU KAISEN - S03E01 (BD 1080p HEVC Opus 2.0).mkv` → `JUJUTSU KAISEN - S03E01.mkv`. If stripping empties the stem (e.g. `[Only Brackets].mkv`), fall back to the unmodified original basename. If two different sources clean to the same output name, the second is skipped by the existing "output already exists" rule (documented consequence; matches v2 semantics). Only balanced groups are removed; an unbalanced `[` or `(` passes through untouched.
9. **CLI & behavior contract:** exactly one directory argument; outputs to `<dir>/converted/<name>.mkv`; skip when the output MKV already exists **and is non-empty** (`-s`, so a zero-byte/partial file from a failed run is re-processed); per-file start/finish/elapsed logging; on any conversion failure the partial output is deleted, the error is counted, and the run exits `1` with `--- Process completed with N file(s) in error. ---`; "--- All tasks are complete. ---" only prints when every conversion succeeded. No external `.srt` sidecar files are produced at all in v3.
10. **Bash safety (from `plex_script_notes.md`):** `set -euo pipefail`; never use `((x++))` (returns 1 and kills the script under `set -e`) — use `x=$((x+1))`; check `first()` jq output for both empty string and literal `"null"`; subtitle codec names are `subrip`, `dvd_subtitle`, `hdmv_pgs_subtitle`, not `srt`, etc.; grep encoders with `ffmpeg -hide_banner -encoders` not synthetic encodes.
11. **Verification/lint:** `bash -n` on every edited script; `shellcheck` (when installed) on bash files; the repo's commit style is a single word `update` (keep it).
12. **NO `grep -q` in pipelines (2026-08-30 fix):** `set -o pipefail` + `grep -q` on a producer is a SIGPIPE race — grep exits on its first match and ffmpeg/ffprobe then die with SIGPIPE (141), so `pipefail` reports the whole pipeline as failed. This silently disabled NVENC detection (see Task 7). Capture producer output into a variable once (`VAR=$(ffmpeg ... || true)`) and string-match with `[[ "$VAR" == *pattern* ]]`. Applies everywhere, including the `ffprobe ... | grep -q "codec_type=video"` guard.
13. **GPU + verify + warn (user decision, 2026-08-30):** re-encodes **always** prefer `hevc_nvenc` — even with a filter chain (resize / fps cap / burn / deinterlace): CPU-decode + CPU-filters + **GPU encode** (`-c:v hevc_nvenc ... -vf <chain>` WITHOUT `-hwaccel cuda`, which only works on the no-filter path). CPU `libx265` is a **_loud warning_ failsafe only** when `hevc_nvenc` is missing; `libx264` is a last-ever fallback. After **every** conversion, `ffprobe` the output's `v:0` codec: re-encodes MUST be `hevc`, copies MUST match the source codec; otherwise delete the output, count an error, and warn loudly.
14. **Auto-deinterlace (user decision, 2026-08-30):** when `field_order` is explicitly interlaced (`tt`/`bb`/`tb`/`bt`), prepend `yadif` to the filter chain instead of blind-copying. Interlaced sources are **never** copy-eligible.
15. **Two-pass subtitle cleanup (user decision, 2026-08-30):** text-based subs that are NOT already `subrip` are extracted to a temp SRT, cleaned with the v2 sed (+ mid-line draw fix), then remuxed as a second input (`-map 1:0 -c:s subrip`). Temp SRT is removed on **both** success and failure; if extraction fails, subtitles are dropped with a warn (the video still converts — subs are best-effort). No external `.srt` survives in `converted/`. Native `subrip` still `-c:s copy`.
16. **`--dry-run` mode (for verification, 2026-08-30):** when the first CLI arg is `--dry-run`, the script prints the encoder matrix, per-file decisions, and the full assembled ffmpeg command, but NEVER executes a conversion (no output MKV, no `converted/` dir, no SRT extraction). This is the mechanism for "random sampling to see if the GPU is used" without ever running a real conversion. Scope note: **only v3 is modified** (v1/v2/iphone keep their behavior, including their own latent SIGPIPE bug).

---

## File Structure

- Create: `ffmpeg/plex_conversion_script_v3.sh` — the rewritten copy-or-normalize script (single deliverable).
- Create: `ffmpeg/tests/make_fixtures.sh` — builds 9 synthetic input fixtures under a work dir (mirroring the proven samples and every decision branch).
- Create: `ffmpeg/tests/verify_v3.sh` — runs v3 against fixtures, asserts output streams against expectations via ffprobe/jq.
- Modify: `ffmpeg/plex_script_notes.md` — update AGENTS-style doc (in Task 6) so it documents v3 behavior, not v2's.
- Leave untouched: `ffmpeg/plex_conversion_script.sh`, `ffmpeg/plex_conversion_script_v2.sh`, `ffmpeg/iphone_conversion_script.sh`, `ffmpeg/clean_existing_srt.sh`.

## Spec & Approved Design (spec this plan implements)

Consolidated from the brainstorming Q&A (rules revised in the final round):

- The **Kaiju No. 8 file (HEVC Main 10, yuv420p10le, 1080p, ~23.81 fps) played on the target TV with zero buffering/transcoding**, proving HEVC Main 10 1080p is direct-play. Both it and the Crushology H.264 file are now copy-eligible targets.
- **Video:** copy both `h264`/`yuv420p` and `hevc`/`yuv420p`+`yuv420p10le`, ceiling ≤1080p and ≤30fps. 10-bit HEVC copies; H.264 Hi10P and HEVC 12-bit re-encode. Re-encode output is **HEVC Main 10** (matching Kaiju). NVENC only when no filter chain; filters force CPU.
- **Audio:** "Copy any aac stereo (44.1k ok)" — the sample-rate bar is removed, and the user confirmed **bitrate is also ignored**: any aac stereo track (128k/192k/320k) copies untouched. Re-encode only >2ch, mono, or non-aac → aac stereo 48k.
- **Subtitle rule (kept from earlier round):** users' validated rule — pick the largest English subtitle; text → mux, image → burn; confirmed English-only (SPA/POR dropped, final); "Never burn without English"; subs muxed inside the MKV (no external `.srt`).
- **Output filename cleanup (added):** strip `[...]` (brackets) and `(...)` (parentheses), plus their contents, from the input basename when naming the output, then collapse + trim whitespace; fall back to the original name if the stripped stem is empty; extension is always `.mkv`. Examples: `[Sokudo] Jujutsu Kaisen - S01E01 v2 [1080p BD AV1][Dual Audio].mkv` → `Jujutsu Kaisen - S01E01 v2.mkv`; `[Purple] JUJUTSU KAISEN - S03E01 (BD 1080p HEVC Opus 2.0).mkv` → `JUJUTSU KAISEN - S03E01.mkv`. Collisions with existing files are handled by the unchanged skip-if-exists rule.
- **Chapters + metadata preserved; attachments dropped (revised, final):** chapters (`-map_chapters 0`, Kaiju's 4 chapters exercise this) and format metadata are preserved. **Cover art and font attachments are intentionally NOT mapped** (user decision 2026-08-29) — fonts are never needed since text subs are re-encoded to subrip and image subs are burned as bitmaps, and Plex supplies its own poster.
- **Ceiling semantics confirmed by user:** "copy when <= target on all attributes; re-encode when strictly above on at least one."

---

### Task 1: Test harness + fixture builder + v3 scaffold

**Files:**
- Create: `ffmpeg/tests/make_fixtures.sh`
- Create: `ffmpeg/tests/verify_v3.sh`
- Create: `ffmpeg/plex_conversion_script_v3.sh`
- Test: `ffmpeg/tests/verify_v3.sh`

**Interfaces:**
- Consumes: nothing (first task).
- Produces:
  - `make_fixtures.sh <baseworkdir>` — creates fixture dirs `f1_sample`, `f2_codec`, `f3_fps`, `f3b_res`, `f4_ac3`, `f5_burn`, `f6_noeng`, `f7_ass`, `f8_brackets` under `<baseworkdir>/`.
  - `verify_v3.sh <script> <workdir>` — reads `$WORK/fixtures`; exit non-zero if any assert fails; prints `ok:` and `FAIL:` lines. Functions for later tasks: `probe()`, `stream_count()`, `stream_prop()`, `attached_count()`, `run_and_log()`.
  - In the scaffold script: `NVENC_HEVC` (0/1) and `HAS_LIBX265` (0/1) flags used by Task 2.

- [ ] **Step 1: Write the failing test — fixture builder**

Create `ffmpeg/tests/make_fixtures.sh`:

```bash
#!/bin/bash
set -euo pipefail
BASE="${1:?usage: make_fixtures.sh <baseworkdir>}"
mkdir -p "$BASE"
for d in f1_sample f2_codec f3_fps f3b_res f4_ac3 f5_burn f6_noeng f7_ass f8_brackets; do rm -rf "$BASE/$d"; done
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ---- f1_sample: mirror of the proven spec: h264/yuv420p + kor aac 48k stereo + eng/spa/por subrip + cover art
mkdir -p "$BASE/f1_sample"
ffmpeg -nostdin -y -v error -f lavfi -i "testsrc2=size=1280x720:rate=24" \
  -f lavfi -i "sine=frequency=1000:duration=2" -t 2 \
  -c:v libx264 -preset veryfast -crf 23 -pix_fmt yuv420p \
  -c:a aac -b:a 160k -ac 2 -ar 48000 \
  -metadata:s:v:0 language=kor -metadata:s:a:0 language=kor \
  "$TMP/f1_base.mkv"
printf '1\n00:00:00,000 --> 00:00:02,000\nHello English\n' > "$TMP/eng.srt"
printf '1\n00:00:00,000 --> 00:00:02,000\nHola Espanol\n'  > "$TMP/spa.srt"
printf '1\n00:00:00,000 --> 00:00:02,000\nOla Portugues\n' > "$TMP/por.srt"
ffmpeg -nostdin -y -v error -i "$TMP/f1_base.mkv" -i "$TMP/eng.srt" -i "$TMP/spa.srt" -i "$TMP/por.srt" \
  -map 0 -map 1 -map 2 -map 3 -map_metadata 0 -c copy \
  -metadata:s:s:0 language=eng   -metadata:s:s:0 title=English \
  -metadata:s:s:1 language=spa   -metadata:s:s:1 title=Espanol \
  -metadata:s:s:2 language=por   -metadata:s:s:2 title=Portugues \
  "$TMP/f1_subs.mkv"
ffmpeg -nostdin -y -v error -f lavfi -i "color=c=red:size=1280x720" -frames:v 1 "$TMP/cover.jpg"
ffmpeg -nostdin -y -v error -i "$TMP/f1_subs.mkv" -i "$TMP/cover.jpg" \
  -map 0 -map 1 -c copy -disposition:v:1 attached_pic -metadata:s:v:1 mimetype=image/jpeg \
  "$BASE/f1_sample/input.mkv"

# ---- f2_codec: mpeg2video 720p (non-h264/non-hevc codec -> normalize to HEVC branch)
mkdir -p "$BASE/f2_codec"
ffmpeg -nostdin -y -v error -f lavfi -i "testsrc2=size=1280x720:rate=24" -t 2 \
  -c:v mpeg2video -q:v 5 \
  "$BASE/f2_codec/input.mkv"

# ---- f3_fps: h264 60fps (fps-cap branch)
mkdir -p "$BASE/f3_fps"
ffmpeg -nostdin -y -v error -f lavfi -i "testsrc2=size=1280x720:rate=60" -t 2 \
  -c:v libx264 -preset veryfast -crf 23 -pix_fmt yuv420p -r 60 \
  "$BASE/f3_fps/input.mkv"

# ---- f3b_res: h264 1920x1200 (resize-down branch)
mkdir -p "$BASE/f3b_res"
ffmpeg -nostdin -y -v error -f lavfi -i "testsrc2=size=1920x1200:rate=24" -t 2 \
  -c:v libx264 -preset veryfast -crf 23 -pix_fmt yuv420p \
  "$BASE/f3b_res/input.mkv"

# ---- f4_ac3: safe h264 video + eng AC3 5.1 48k (audio re-encode branch)
mkdir -p "$BASE/f4_ac3"
ffmpeg -nostdin -y -v error -f lavfi -i "testsrc2=size=1280x720:rate=24" \
  -f lavfi -i "sine=frequency=800:duration=2" -t 2 \
  -c:v libx264 -preset veryfast -crf 23 -pix_fmt yuv420p \
  -c:a ac3 -b:a 384k -ac 6 -ar 48000 -metadata:s:a:0 language=eng \
  "$BASE/f4_ac3/input.mkv"

# ---- f5_burn: safe h264 video + eng PGS image sub (burn branch)
mkdir -p "$BASE/f5_burn"
ffmpeg -nostdin -y -v error -f lavfi -i "testsrc2=size=1280x720:rate=24" -t 2 \
  -c:v libx264 -preset veryfast -crf 23 -pix_fmt yuv420p \
  "$TMP/f5_vid.mkv"
printf '1\n00:00:00,000 --> 00:00:02,000\nBurned English\n' > "$TMP/f5.srt"
ffmpeg -nostdin -y -v error -i "$TMP/f5_vid.mkv" -i "$TMP/f5.srt" \
  -map 0 -map 1 -c copy -c:s hdmv_pgs_subtitle -metadata:s:s:0 language=eng \
  "$BASE/f5_burn/input.mkv"

# ---- f6_noeng: safe h264 video + spa subrip ONLY (no-English branch)
mkdir -p "$BASE/f6_noeng"
ffmpeg -nostdin -y -v error -i "$TMP/f5_vid.mkv" -i "$TMP/spa.srt" \
  -map 0 -map 1 -c copy -metadata:s:s:0 language=spa \
  "$BASE/f6_noeng/input.mkv"

# ---- f7_ass: safe h264 video + eng ASS text sub (text->subrip conversion branch)
mkdir -p "$BASE/f7_ass"
ffmpeg -nostdin -y -v error -i "$TMP/f5_vid.mkv" -i "$TMP/eng.srt" \
  -map 0 -map 1 -c copy -c:s ass -metadata:s:s:0 language=eng \
  "$BASE/f7_ass/input.mkv"

# ---- f8_brackets: filename with [..] and (..) groups -> output name must be cleaned
# reuses f5_vid (safe h264/yuv420p/720p24) with a fansub-style name (brackets + parens).
# The naming logic is scaffold-level (Task 1 Step 5); the assert lives in Task 2.
mkdir -p "$BASE/f8_brackets"
cp "$TMP/f5_vid.mkv" "$BASE/f8_brackets/[Sokudo] Jujutsu Kaisen - S01E01 v2 (BD 1080p)[1080p BD AV1][Dual Audio].mkv"

echo "Fixtures ready under: $BASE"
```

- [ ] **Step 2: Run the fixture builder**

Run: `bash ffmpeg/tests/make_fixtures.sh /tmp/opencode/plex-v3-work/fixtures && ls /tmp/opencode/plex-v3-work/fixtures`
Expected: `input.mkv` under all 8 fixture dirs above. Spot-check `f1_sample` with `ffprobe` (h264 + kor aac stereo + 3 subrip + 1 attached pic), `f2_codec` (mpeg2video), `f5_burn` (hdmv_pgs_subtitle).

- [ ] **Step 3: Write the failing test — verify harness smoke test**

Create `ffmpeg/tests/verify_v3.sh`:

```bash
#!/bin/bash
set -euo pipefail
V3="${1:-}"
WORK="${2:-}"
if [ -z "$V3" ] || [ -z "$WORK" ]; then
  echo "usage: $0 /path/to/plex_conversion_script_v3.sh /path/to/work" >&2
  exit 2
fi

FAILS=0
fail() { echo "FAIL: $*" >&2; FAILS=$((FAILS + 1)); }
ok()   { echo "ok: $*"; }

probe() { ffprobe -v quiet -print_format json -show_format -show_streams "$1"; }

stream_count() { probe "$1" | jq "[.streams[] | select(.codec_type==\"$2\")] | length"; }

stream_prop() { # file typeidx-in-type key
  probe "$1" | jq -r --arg t "$2" --arg i "$3" --arg k "$4" \
    '[.streams[] | select(.codec_type==$t)] | .[($i|tonumber)] | .[$k] // ""'
}

attached_count() { probe "$1" | jq '[.streams[] | select(.disposition.attached_pic? == 1)] | length'; }

run_and_log() { # fixture_dir
  "$V3" "$1" > "$WORK/run.log" 2>&1 || { fail "script exited non-zero on $1"; echo "-- log --" >&2; cat "$WORK/run.log" >&2; return 1; }
}

# ---- 0. Smoke: empty dir must run clean
EMPTY="$WORK/empty"
rm -rf "$EMPTY"
mkdir -p "$EMPTY"
"$V3" "$EMPTY" > "$WORK/smoke.log" 2>&1
grep -q "All tasks are complete" "$WORK/smoke.log" && ok "smoke: empty dir ran clean" || fail "smoke: missing completion line"
```

- [ ] **Step 4: Run the test to verify it fails**

Run: `bash ffmpeg/tests/verify_v3.sh ffmpeg/plex_conversion_script_v3.sh /tmp/opencode/plex-v3-work`
Expected: FAIL because `plex_conversion_script_v3.sh` does not exist yet (`bash: ...: No such file or directory`).

- [ ] **Step 5: Write minimal scaffold implementation**

Create `ffmpeg/plex_conversion_script_v3.sh` (full v2 scaffolding preserved, stream logic empty):

```bash
#!/bin/bash
set -euo pipefail

for cmd in ffmpeg ffprobe jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "!! CRITICAL ERROR: Required command '$cmd' is not installed." >&2
    exit 1
  fi
done

# --- Encoder detection (NVENC HEVC + software x265) ---
NVENC_HEVC=0
HAS_LIBX265=0
if nvidia-smi &>/dev/null; then
  if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q hevc_nvenc; then
    NVENC_HEVC=1
    echo "--- NVIDIA NVENC HEVC encoding enabled ---"
  fi
fi
if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q libx265; then
  HAS_LIBX265=1
fi

if [ "$#" -ne 1 ]; then
  echo "!! USAGE ERROR: You must provide exactly one argument." >&2
  echo "   Usage: $0 \"/path/to/your/videos\"" >&2
  exit 1
fi

INPUT_ROOT_DIR="$1"
if [ ! -d "$INPUT_ROOT_DIR" ]; then
  echo "!! PATH ERROR: The provided path is not a valid directory." >&2
  echo "   Provided: '$INPUT_ROOT_DIR'" >&2
  exit 1
fi

echo "--- Starting process in: $INPUT_ROOT_DIR ---"

ANY_FAIL=0

# process substitution (not a pipe) so ANY_FAIL survives the loop in the
# parent shell; find prunes the converted/ output subtree (fix #4/#5)
while IFS= read -r SOURCE_FILE; do
  start_time=$(date +%s)
  start_time_human=$(date '+%Y-%m-%d %H:%M:%S')

  if ! ffprobe -v error -select_streams v:0 -show_entries stream=codec_type "$SOURCE_FILE" 2>/dev/null | grep -q "codec_type=video"; then
    continue
  fi

  DIR_NAME=$(dirname "$SOURCE_FILE")
  BASE_NAME=$(basename "$SOURCE_FILE")
  FILE_NAME_NO_EXT="${BASE_NAME%.*}"
  # v3 filename cleanup (Global Constraint #8): strip balanced [..] and (..)
  # groups, collapse whitespace runs to one space, trim leading/trailing space.
  CLEANED_NAME=$(printf '%s' "$FILE_NAME_NO_EXT" | sed -E 's/\[[^]]*\]//g; s/\([^)]*\)//g; s/[[:space:]]+/ /g; s/^[[:space:]]+//; s/[[:space:]]+$//')
  if [ -n "$CLEANED_NAME" ]; then
    FILE_NAME_NO_EXT="$CLEANED_NAME"
  fi
  OUTPUT_DIR="$DIR_NAME/converted"
  OUTPUT_FILE_MKV="$OUTPUT_DIR/${FILE_NAME_NO_EXT}.mkv"

  echo "==============================================================="
  echo ">> Processing video: [ $FILE_NAME_NO_EXT ]"

  if [ -s "$OUTPUT_FILE_MKV" ]; then
    echo "   [SKIP]: Output file already exists (non-empty)."
    continue
  fi

  mkdir -p "$OUTPUT_DIR"

  echo "   [TODO]: stream logic not yet implemented for: $SOURCE_FILE"

  echo "Started:  $start_time_human"
  echo "Finished: $(date '+%Y-%m-%d %H:%M:%S')"
done < <(find "$INPUT_ROOT_DIR" -name "converted" -prune -o -type f -printf '%f\t%p\n' | sort -k1 | cut -f2)

if (( ANY_FAIL > 0 )); then
  echo "--- Process completed with ${ANY_FAIL} file(s) in error. ---"
  exit 1
fi
echo "--- All tasks are complete. ---"
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `bash -n ffmpeg/plex_conversion_script_v3.sh && bash ffmpeg/tests/verify_v3.sh ffmpeg/plex_conversion_script_v3.sh /tmp/opencode/plex-v3-work`
Expected: `ok: smoke: empty dir ran clean` and exit 0. Also run `command -v shellcheck >/dev/null && shellcheck -S warning ffmpeg/plex_conversion_script_v3.sh ffmpeg/tests/*.sh || echo "shellcheck not installed"`.

- [ ] **Step 7: Commit**

```bash
git add ffmpeg/plex_conversion_script_v3.sh ffmpeg/tests/make_fixtures.sh ffmpeg/tests/verify_v3.sh
git commit -m "update"
```

---

### Task 2: Video decision section

**Files:**
- Modify: `ffmpeg/plex_conversion_script_v3.sh` (inside the `while read` loop, replace the `[TODO]` line)
- Modify: `ffmpeg/tests/verify_v3.sh` (add fixture video asserts)
- Test: `ffmpeg/tests/verify_v3.sh`

**Interfaces:**
- Consumes: Task 1 scaffold loop; `NVENC_HEVC` and `HAS_LIBX265` flags (Task 1). `JSON_PROBE` is created in this task, consumed by Tasks 3–5.
- Produces:
  - `VID_INDEX` (int, stream index of the first real video stream — mapped as `-map 0:VID_INDEX`)
  - `VIDEO_OPTS` (bash array of encoder/copy flags)
  - `VIDEO_FILTERS` (string, comma-joined `-vf` body; empty when none)
  - `HWACCEL` (string; set only on the NVENC path)
  - log lines the harness greps: `[VIDEO]:` heading lines.

- [ ] **Step 1: Write the failing test — fixture video asserts**

Append to `ffmpeg/tests/verify_v3.sh` (after Task 1's smoke block):

```bash
# ---- Video asserts ----------------------------------------------
FXD="$WORK/fixtures"

# f1_sample: h264 yuv420p 720p24 -> COPY keeps codec/dims/pix_fmt
F1="$FXD/f1_sample"
run_and_log "$F1"
[ "$(stream_count "$F1/converted/input.mkv" video)" = "1" ] && ok "f1: one video" || fail "f1: video count"
[ "$(stream_prop "$F1/converted/input.mkv" video 0 codec_name)" = "h264" ] && ok "f1: h264" || fail "f1: codec"
[ "$(stream_prop "$F1/converted/input.mkv" video 0 pix_fmt)" = "yuv420p" ] && ok "f1: yuv420p" || fail "f1: pix_fmt"
grep -q "Copying stream" "$WORK/run.log" && ok "f1: log says copy" || fail "f1: log not copy"

# f2_codec: mpeg2video -> normalized to HEVC Main 10
F2="$FXD/f2_codec"
run_and_log "$F2"
[ "$(stream_prop "$F2/converted/input.mkv" video 0 codec_name)" = "hevc" ] && ok "f2: normalized to hevc" || fail "f2: codec"
[ "$(stream_prop "$F2/converted/input.mkv" video 0 pix_fmt)" = "yuv420p10le" ] && ok "f2: 10-bit" || fail "f2: pix_fmt"
grep -q "Needs re-encode" "$WORK/run.log" && ok "f2: log says re-encode" || fail "f2: log"

# f3_fps: 60fps h264 -> fps capped at 30, HEVC output (CPU filter path)
F3="$FXD/f3_fps"
run_and_log "$F3"
[ "$(stream_prop "$F3/converted/input.mkv" video 0 codec_name)" = "hevc" ] && ok "f3: hevc" || fail "f3: codec"
F3_FPS=$(stream_prop "$F3/converted/input.mkv" video 0 avg_frame_rate)
F3_NUM=$(echo "$F3_FPS" | cut -d/ -f1); F3_DEN=$(echo "$F3_FPS" | cut -d/ -f2)
F3_VAL=$(awk -v n="$F3_NUM" -v d="$F3_DEN" 'BEGIN{ print (d>0)? n/d : 0 }')
awk -v v="$F3_VAL" 'BEGIN{ exit !(v<=30.001) }' && ok "f3: fps<=30 ($F3_VAL)" || fail "f3: fps uncapped ($F3_VAL)"
grep -q "CPU libx265" "$WORK/run.log" && ok "f3: CPU filter path" || fail "f3: expected CPU path"

# f3b_res: 1920x1200 -> scaled to <=1080, even dims, HEVC
F3B="$FXD/f3b_res"
run_and_log "$F3B"
[ "$(stream_prop "$F3B/converted/input.mkv" video 0 codec_name)" = "hevc" ] && ok "f3b: hevc" || fail "f3b: codec"
F3B_H=$(stream_prop "$F3B/converted/input.mkv" video 0 height)
[ "$F3B_H" -le 1080 ] && [ $((F3B_H % 2)) -eq 0 ] && ok "f3b: height $F3B_H even <=1080" || fail "f3b: height $F3B_H"

# f8_brackets: [..] groups stripped from the output name (Global Constraint #8)
F8="$FXD/f8_brackets"
run_and_log "$F8"
[ -f "$F8/converted/Jujutsu Kaisen - S01E01 v2.mkv" ] && ok "f8: [..] and (..) stripped from output name" || fail "f8: output name not cleaned"
[ "$(stream_prop "$F8/converted/Jujutsu Kaisen - S01E01 v2.mkv" video 0 codec_name)" = "h264" ] && ok "f8: video copied under clean name" || fail "f8: video under clean name"
[ ! -f "$F8/converted/[Sokudo] Jujutsu Kaisen - S01E01 v2 (BD 1080p)[1080p BD AV1][Dual Audio].mkv" ] && ok "f8: raw name not used" || fail "f8: raw bracketed output exists"
```

- [ ] **Step 2: Build fixtures under the harness's expected path**

Run: `rm -rf /tmp/opencode/plex-v3-work/fixtures && bash ffmpeg/tests/make_fixtures.sh /tmp/opencode/plex-v3-work/fixtures`
(When executing the plan, substitute `/tmp/opencode/plex-v3-work` with the chosen work dir consistently. The harness reads `$WORK/fixtures`.)

- [ ] **Step 3: Run the test to verify it fails**

Run: `bash ffmpeg/tests/verify_v3.sh ffmpeg/plex_conversion_script_v3.sh /tmp/opencode/plex-v3-work`
Expected: FAILs (outputs exist but are empty MKVs / the log lacks `Copying stream`, etc.) because the video section is not implemented.

- [ ] **Step 4: Implement the video decision section**

Replace the `[TODO]` line in `ffmpeg/plex_conversion_script_v3.sh` with:

```bash
  JSON_PROBE=$(ffprobe -v quiet -print_format json -show_format -show_streams "$SOURCE_FILE")
  echo "   Target for conversion: $OUTPUT_FILE_MKV"

  # ---- 1. First REAL video stream (exclude attached pictures) ----
  VIDEO_STREAM_JSON=$(echo "$JSON_PROBE" | jq 'first(.streams[] | select(.codec_type=="video" and (.disposition.attached_pic? != 1)))')
  if [ -z "$VIDEO_STREAM_JSON" ] || [ "$VIDEO_STREAM_JSON" == "null" ]; then
    echo "   !! ERROR: Could not find a video stream in this file. Skipping."
    continue
  fi
  VID_INDEX=$(echo "$VIDEO_STREAM_JSON" | jq -r '.index')
  CODEC=$(echo "$VIDEO_STREAM_JSON" | jq -r '.codec_name')
  WIDTH=$(echo "$VIDEO_STREAM_JSON" | jq -r '.width')
  HEIGHT=$(echo "$VIDEO_STREAM_JSON" | jq -r '.height')
  PIX_FMT=$(echo "$VIDEO_STREAM_JSON" | jq -r '.pix_fmt // "yuv420p"')
  FPS_NUM=$(echo "$VIDEO_STREAM_JSON" | jq -r '.avg_frame_rate // "0/1" | split("/")[0]')
  FPS_DEN=$(echo "$VIDEO_STREAM_JSON" | jq -r '.avg_frame_rate // "0/1" | split("/")[1]')
  FPS_DEC=$(awk -v n="$FPS_NUM" -v d="$FPS_DEN" 'BEGIN{ print (d > 0) ? n / d : 0 }')
  FPS_INT=${FPS_DEC%.*}

  # NOTE: BURN_FILTER is set by the subtitle section (Task 4) BEFORE this block.
  #       ${BURN_FILTER:-} is safe under set -u until then.

  # ---- 3. Video decision ----
  # Proven copy ceiling: h264/yuv420p OR hevc/yuv420p|yuv420p10le, <=1920x1088, <=30fps, no burn.
  VIDEO_FILTERS=""
  VIDEO_OPTS=()
  HWACCEL=""
  SAFE_VIDEO=0
  case "$CODEC" in
    h264)
      if [ "$PIX_FMT" == "yuv420p" ] && (( WIDTH <= 1920 )) && (( HEIGHT <= 1088 )) && (( FPS_INT <= 30 )); then
        SAFE_VIDEO=1
      fi
      ;;
    hevc)
      if { [ "$PIX_FMT" == "yuv420p" ] || [ "$PIX_FMT" == "yuv420p10le" ]; } \
            && (( WIDTH <= 1920 )) && (( HEIGHT <= 1088 )) && (( FPS_INT <= 30 )); then
        SAFE_VIDEO=1
      fi
      ;;
  esac

  if (( SAFE_VIDEO )) && [ -z "${BURN_FILTER:-}" ]; then
    echo "   [VIDEO]: Proven-compatible (${CODEC}, ${WIDTH}x${HEIGHT}, ${PIX_FMT}, ${FPS_DEC} fps). Copying stream."
    VIDEO_OPTS=(-c:v copy)
  else
    echo "   [VIDEO]: Needs re-encode (${CODEC}, ${WIDTH}x${HEIGHT}, ${PIX_FMT}, ${FPS_DEC} fps, burn=$(if [ -n "${BURN_FILTER:-}" ]; then echo yes; else echo no; fi))."
    if (( WIDTH > 1920 )) || (( HEIGHT > 1088 )); then
      VIDEO_FILTERS="scale=1920:1080:force_original_aspect_ratio=decrease:flags=lanczos,scale=trunc(iw/2)*2:trunc(ih/2)*2,setsar=1"
    fi
    if (( FPS_INT > 30 )); then
      [ -n "$VIDEO_FILTERS" ] && VIDEO_FILTERS+=","
      VIDEO_FILTERS+="fps=30"
    fi
    if [ -n "${BURN_FILTER:-}" ]; then
      [ -n "$VIDEO_FILTERS" ] && VIDEO_FILTERS+=","
      VIDEO_FILTERS+="$BURN_FILTER"
    fi

    if [ -n "$VIDEO_FILTERS" ]; then
      if (( HAS_LIBX265 )); then
        echo "   [VIDEO]: Re-encoding via CPU libx265 (filter chain: $VIDEO_FILTERS)."
        VIDEO_OPTS=(-c:v libx265 -preset medium -crf 22 -pix_fmt yuv420p10le -vf "$VIDEO_FILTERS")
      else
        echo "   [VIDEO]: Re-encoding via CPU libx264 (filter chain: $VIDEO_FILTERS; no libx265)."
        VIDEO_OPTS=(-c:v libx264 -preset medium -crf 19 -pix_fmt yuv420p -vf "$VIDEO_FILTERS")
      fi
    elif (( NVENC_HEVC )); then
      echo "   [VIDEO]: Re-encoding via NVENC HEVC (no filter chain needed)."
      HWACCEL="-hwaccel cuda -hwaccel_output_format cuda"
      VIDEO_OPTS=(-c:v hevc_nvenc -preset p7 -tune hq -cq 27 -rc vbr -multipass 1 -b_ref_mode middle -bf 4 -spatial-aq 1 -temporal-aq 1 -rc-lookahead 32 -pix_fmt yuv420p10le)
    elif (( HAS_LIBX265 )); then
      echo "   [VIDEO]: Re-encoding via CPU libx265."
      VIDEO_OPTS=(-c:v libx265 -preset medium -crf 22 -pix_fmt yuv420p10le)
    else
      echo "   [VIDEO]: Re-encoding via CPU libx264 (no libx265)."
      VIDEO_OPTS=(-c:v libx264 -preset medium -crf 19 -pix_fmt yuv420p)
    fi
  fi

  # ---- 6a. Assemble and execute (video-only for THIS task) ----
  echo "   Building final MKV conversion command..."
  COMMAND=(ffmpeg -nostdin -hide_banner -v error -stats $HWACCEL -i "$SOURCE_FILE" -map 0:$VID_INDEX)
  COMMAND+=("${VIDEO_OPTS[@]}")
  COMMAND+=(-map_chapters 0 -map_metadata 0 -y "$OUTPUT_FILE_MKV")

  echo "   Executing: ${COMMAND[*]}"
  if "${COMMAND[@]}"; then
    echo "   SUCCESS: MKV file created successfully."
  else
    echo "   !! FFMPEG ERROR: MKV conversion failed." >&2
  fi

  end_time=$(date +%s)
  end_time_human=$(date '+%Y-%m-%d %H:%M:%S')
  elapsed=$((end_time - start_time))
  echo "Started:  $start_time_human"
  echo "Finished: $end_time_human"
  echo "Elapsed time for $FILE_NAME_NO_EXT: ${elapsed} seconds"
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash -n ffmpeg/plex_conversion_script_v3.sh && bash ffmpeg/tests/verify_v3.sh ffmpeg/plex_conversion_script_v3.sh /tmp/opencode/plex-v3-work`
Expected: all Task-2 `ok:` lines pass (f1 copy, f2 hevc-10bit, f3 hevc+cap+CPU, f3b hevc+even≤1080, **f8 `[..]`/`(..)`-cleaned output name**). The Task-1 smoke `ok:` stays green.

- [ ] **Step 6: Commit**

```bash
git add ffmpeg/plex_conversion_script_v3.sh ffmpeg/tests/verify_v3.sh
git commit -m "update"
```

---

### Task 3: Audio decision section

**Files:**
- Modify: `ffmpeg/plex_conversion_script_v3.sh` (add audio section before the "Assemble and execute" block; extend the assemble block)
- Modify: `ffmpeg/tests/verify_v3.sh` (add audio asserts)
- Test: `ffmpeg/tests/verify_v3.sh`

**Interfaces:**
- Consumes: `JSON_PROBE` (Task 2).
- Produces: `AUDIO_MAPS`, `AUDIO_CODEC_OPTS`, `AUDIO_METADATA_OPTS` (strings, appended to `COMMAND`). Keeps all KOR/JPN/ENG streams in priority order; falls back to first audio if none match.

- [ ] **Step 1: Write the failing test — fixture audio asserts**

Append to `ffmpeg/tests/verify_v3.sh`:

```bash
# ---- Audio asserts ------------------------------------------------
# f1_sample: kor aac 48k stereo -> copied
run_and_log "$F1"
[ "$(stream_count "$F1/converted/input.mkv" audio)" = "1" ] && ok "f1: one audio" || fail "f1: audio count"
[ "$(stream_prop "$F1/converted/input.mkv" audio 0 codec_name)" = "aac" ]          && ok "f1: aac"          || fail "f1: audio codec"
[ "$(stream_prop "$F1/converted/input.mkv" audio 0 sample_rate)" = "48000" ]       && ok "f1: 48k"          || fail "f1: sample_rate"
[ "$(stream_prop "$F1/converted/input.mkv" audio 0 channels)" = "2" ]              && ok "f1: stereo"       || fail "f1: channels"
[ "$(stream_prop "$F1/converted/input.mkv" audio 0 language)" = "kor" ]            && ok "f1: kor"          || fail "f1: language"

# f1b: ADD a 44.1kHz HIGH-BITRATE (320k) stereo track to f1's fixture to prove
# sample-rate AND bitrate are ignored by the copy bar. The 44.1kHz assert below
# already proves copy (a re-encode would force 48k); the 320k source exercises the bitrate side.
F1B_SRC="$F1/input.mkv"
F1B="$FXD/f1b_441"
mkdir -p "$F1B"
ffmpeg -nostdin -y -v error -i "$F1B_SRC" \
  -f lavfi -i "sine=frequency=500:duration=2" \
  -map 0:0 -map 0:1 -map 1 -c:v copy -c:a:0 copy -c:a:1 aac -b:a:1 320k -ac:1 2 -ar:1 44100 \
  -metadata:s:a:1 language=eng -metadata:s:a:1 title=English \
  "$F1B/input.mkv"
run_and_log "$F1B"
[ "$(stream_count "$F1B/converted/input.mkv" audio)" = "2" ] && ok "f1b: two audio" || fail "f1b: audio count"
[ "$(stream_prop "$F1B/converted/input.mkv" audio 1 codec_name)" = "aac" ]    && ok "f1b: eng aac"  || fail "f1b: eng codec"
[ "$(stream_prop "$F1B/converted/input.mkv" audio 1 sample_rate)" = "44100" ] && ok "f1b: 44.1k kept" || fail "f1b: 44.1k"
grep -q "Copying" "$WORK/run.log" && ok "f1b: eng copied" || fail "f1b: eng was re-encoded"

# f4_ac3: eng AC3 5.1 -> aac stereo 48k
F4="$FXD/f4_ac3"
run_and_log "$F4"
[ "$(stream_prop "$F4/converted/input.mkv" audio 0 codec_name)" = "aac" ]          && ok "f4: aac"          || fail "f4: audio codec"
[ "$(stream_prop "$F4/converted/input.mkv" audio 0 channels)" = "2" ]              && ok "f4: stereo"       || fail "f4: channels"
[ "$(stream_prop "$F4/converted/input.mkv" audio 0 sample_rate)" = "48000" ]       && ok "f4: 48k"          || fail "f4: sample_rate"
[ "$(stream_prop "$F4/converted/input.mkv" audio 0 language)" = "eng" ]            && ok "f4: eng tag"      || fail "f4: language"
grep -q "Re-encoding" "$WORK/run.log" && ok "f4: log says re-encode" || fail "f4: log"
```

Note: `stream_prop` reads key `language`, which ffprobe emits from stream tags as `language`. If the installed ffprobe builds the JSON key differently, adjust the assert to `tags.language` — verify with `ffprobe -v quiet -print_format json -show_streams <out>`.

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash ffmpeg/tests/verify_v3.sh ffmpeg/plex_conversion_script_v3.sh /tmp/opencode/plex-v3-work`
Expected: audio FAILs (output has 0 audio streams — Task 2's video-only assembly).

- [ ] **Step 3: Implement the audio decision section**

Insert this block directly above the `# ---- 6a. Assemble and execute` block in `ffmpeg/plex_conversion_script_v3.sh`:

```bash
  # ---- 4. Audio decision ----
  # KOR -> JPN -> ENG priority; ALL languages kept; everything else dropped.
  # Copy per-stream only if aac + stereo (sample rate AND bitrate IRRELEVANT: 44.1k/48k, 128k/320k proven);
  # else re-encode to aac 192k stereo 48k (5.1+/non-stereo downmixed).
  AUDIO_MAPS=""
  AUDIO_CODEC_OPTS=""
  AUDIO_METADATA_OPTS=""
  audio_counter=0
  AUDIO_STREAMS_JSON=$(echo "$JSON_PROBE" | jq -c '
    [.streams[] | select(.codec_type=="audio")]
    | map(select((.tags.language? // "" | ascii_downcase) as $l | $l == "kor" or $l == "ko" or $l == "jpn" or $l == "ja" or $l == "eng" or $l == "en"))
    | sort_by(
        if (.tags.language? // "" | ascii_downcase) == "kor" or (.tags.language? // "" | ascii_downcase) == "ko" then 0
        elif (.tags.language? // "" | ascii_downcase) == "jpn" or (.tags.language? // "" | ascii_downcase) == "ja" then 1
        else 2 end
      , .index)
    | .[]
  ')
  if [ -n "$AUDIO_STREAMS_JSON" ] && [ "$AUDIO_STREAMS_JSON" != "null" ]; then
    while IFS= read -r audio_stream_json; do
      lang=$(echo "$audio_stream_json" | jq -r '(.tags.language? // "" | ascii_downcase)')
      idx=$(echo "$audio_stream_json" | jq -r '.index')
      ch=$(echo "$audio_stream_json" | jq -r '.channels // 2')
      sr=$(echo "$audio_stream_json" | jq -r '.sample_rate // 0')
      acodec=$(echo "$audio_stream_json" | jq -r '.codec_name')
      case "$lang" in
        kor | ko) lang_name="Korean" ;;
        jpn | ja) lang_name="Japanese" ;;
        eng | en) lang_name="English" ;;
        *)        lang_name="Audio" ;;
      esac
      echo "   [AUDIO]: ${lang_name} (${acodec}, ${ch}ch, ${sr}Hz) at stream $idx."
      AUDIO_MAPS+="-map 0:$idx "
      if [ "$acodec" == "aac" ] && (( ch == 2 )); then
        echo "     - Action: Copying (aac stereo — any sample rate/bitrate is proven)."
        AUDIO_CODEC_OPTS+="-c:a:$audio_counter copy "
      else
        echo "     - Action: Re-encoding to stereo AAC-LC 48kHz (192k)."
        AUDIO_CODEC_OPTS+="-c:a:$audio_counter aac -b:a:$audio_counter 192k -ac:a:$audio_counter 2 -ar:a:$audio_counter 48000 "
      fi
      AUDIO_METADATA_OPTS+="-metadata:s:a:$audio_counter language=$lang "
      audio_counter=$((audio_counter + 1))
    done < <(echo "$AUDIO_STREAMS_JSON")
  fi

  if [ -z "$AUDIO_MAPS" ]; then
    FIRST_AUDIO_INDEX=$(echo "$JSON_PROBE" | jq 'first(.streams[] | select(.codec_type=="audio") | .index)')
    if [ -n "$FIRST_AUDIO_INDEX" ] && [ "$FIRST_AUDIO_INDEX" != "null" ]; then
      echo "   [AUDIO]: No KOR/JPN/ENG audio. Falling back to first audio stream at $FIRST_AUDIO_INDEX -> stereo AAC 48kHz."
      AUDIO_MAPS="-map 0:$FIRST_AUDIO_INDEX"
      AUDIO_CODEC_OPTS="-c:a aac -b:a 192k -ac 2 -ar 48000"
      AUDIO_METADATA_OPTS="-metadata:s:a:0 language=und"
    else
      echo "   [AUDIO]: No audio streams found. No audio in the output."
    fi
  fi
```

Then update the assemble block (replace the last `COMMAND+=(-map_chapters ...)` line) to:

```bash
  if [ -n "$AUDIO_MAPS" ]; then COMMAND+=($AUDIO_MAPS $AUDIO_CODEC_OPTS $AUDIO_METADATA_OPTS); fi
  COMMAND+=(-map_chapters 0 -map_metadata 0 -y "$OUTPUT_FILE_MKV")
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash -n ffmpeg/plex_conversion_script_v3.sh && bash ffmpeg/tests/verify_v3.sh ffmpeg/plex_conversion_script_v3.sh /tmp/opencode/plex-v3-work`
Expected: all `f1:` and `f1b:` and `f4:` audio `ok:` lines pass (kor aac 48k copied; **eng aac 44.1kHz @ 320k copied untouched** — proving bitrate is not a copy threshold; ac3 5.1 → aac stereo 48k), plus all previous `ok:` lines.

- [ ] **Step 5: Commit**

```bash
git add ffmpeg/plex_conversion_script_v3.sh ffmpeg/tests/verify_v3.sh
git commit -m "update"
```

---

### Task 4: Subtitle decision section

**Files:**
- Modify: `ffmpeg/plex_conversion_script_v3.sh` (add subtitle section BEFORE the video section; wire `BURN_FILTER` and `SUB_MAP_OPTS` into assembly)
- Modify: `ffmpeg/tests/verify_v3.sh` (add subtitle asserts)
- Test: `ffmpeg/tests/verify_v3.sh`

**Interfaces:**
- Consumes: `JSON_PROBE` (Task 2).
- Produces:
  - `SUB_MAP_OPTS` (string: `-map 0:<idx> -c:s copy|subrip -metadata:s:s:0 language=eng` when the largest English sub is text) — appended to `COMMAND`.
  - `BURN_FILTER` (string `subtitles='<escaped-path>':si=<idx>` when the largest English sub is image-based) — consumed by Task 2's video section (now active).

- [ ] **Step 1: Write the failing test — fixture subtitle asserts**

Append to `ffmpeg/tests/verify_v3.sh`:

```bash
# ---- Subtitle asserts --------------------------------------------
# f1_sample: largest English (subrip, text) muxed; SPA/POR dropped
run_and_log "$F1"
[ "$(stream_count "$F1/converted/input.mkv" subtitle)" = "1" ] && ok "f1: one subtitle" || fail "f1: sub count"
[ "$(stream_prop "$F1/converted/input.mkv" subtitle 0 codec_name)" = "subrip" ] && ok "f1: subrip" || fail "f1: sub codec"
[ "$(stream_prop "$F1/converted/input.mkv" subtitle 0 language)" = "eng" ]      && ok "f1: eng"    || fail "f1: sub language"

# f5_burn: eng PGS image sub -> burned, zero subtitle streams remain
F5="$FXD/f5_burn"
run_and_log "$F5"
[ "$(stream_count "$F5/converted/input.mkv" subtitle)" = "0" ] && ok "f5: no subs (burned)" || fail "f5: sub count"
grep -q "image-based" "$WORK/run.log" && ok "f5: log burning" || fail "f5: log"
[ "$(stream_prop "$F5/converted/input.mkv" video 0 codec_name)" = "hevc" ] && ok "f5: burned video re-encoded hevc" || fail "f5: burned video codec"

# f6_noeng: only a spa sub, no English -> no subs, no burn, video copied
F6="$FXD/f6_noeng"
run_and_log "$F6"
[ "$(stream_count "$F6/converted/input.mkv" subtitle)" = "0" ] && ok "f6: no subs" || fail "f6: sub count"
grep -q "No English subtitle" "$WORK/run.log" && ok "f6: log" || fail "f6: log"
grep -q "Copying stream" "$WORK/run.log" && ok "f6: video copied" || fail "f6: f6 video not copied"

# f7_ass: eng ASS text sub -> converted and muxed as subrip
F7="$FXD/f7_ass"
run_and_log "$F7"
[ "$(stream_count "$F7/converted/input.mkv" subtitle)" = "1" ] && ok "f7: one subtitle" || fail "f7: sub count"
[ "$(stream_prop "$F7/converted/input.mkv" subtitle 0 codec_name)" = "subrip" ] && ok "f7: subrip" || fail "f7: sub codec"

# f3_fps unaffected by the subtitle section: still capped
run_and_log "$F3"
F3_FPS=$(stream_prop "$F3/converted/input.mkv" video 0 avg_frame_rate)
F3_NUM=$(echo "$F3_FPS" | cut -d/ -f1); F3_DEN=$(echo "$F3_FPS" | cut -d/ -f2)
F3_VAL=$(awk -v n="$F3_NUM" -v d="$F3_DEN" 'BEGIN{ print (d>0)? n/d : 0 }')
awk -v v="$F3_VAL" 'BEGIN{ exit !(v<=30.001) }' && ok "f3: fps still capped" || fail "f3: fps uncapped"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash ffmpeg/tests/verify_v3.sh ffmpeg/plex_conversion_script_v3.sh /tmp/opencode/plex-v3-work`
Expected: subtitle FAILs (`f1: sub count`, `f5`, `f6`, `f7`) — subtitle section not implemented.

- [ ] **Step 3: Implement the subtitle decision section**

Place the subtitle block **immediately after the `JSON_PROBE=` line and BEFORE the `# ---- 1. First REAL video stream` block** (the video section consumes `BURN_FILTER`; its `case`/`if` reads `${BURN_FILTER:-}`). Insert:

```bash
  # ---- 2. English subtitle decision (English-only; one largest track) ----
  # largest English sub by size (NUMBER_OF_BYTES -> BPS*DURATION -> DURATION alone
  #   -> bit_rate*duration -> 0). The "DURATION alone" fallback (reached when BPS
  #   is missing, e.g. Unicorn Re0096) ranks per-stream duration so a stats-less
  #   Full track still beats a stats-less Signs/opening track deterministically.
  #   text-based  -> muxed embedded as subrip (copy if already subrip, else convert)
  #   image-based -> BURNED into the video (forces CPU re-encode)
  SUB_MAP_OPTS=""
  BURN_FILTER=""
  ENGLISH_SUB_JSON=$(echo "$JSON_PROBE" | jq -c '
    ([.streams[] | select(.codec_type=="subtitle" and ((.tags.language? // "" | ascii_downcase) as $l | $l == "eng" or $l == "en"))]
     | map(. as $s | {
         st: $s,
         # ffprobe emits NUMBER_OF_BYTES/BPS/DURATION as STRINGS; mkvmerge <98
         # namespaces them per language as NUMBER_OF_BYTES-eng / BPS-eng /
         # DURATION-eng. Coerce with tonumber?, read both key forms, treat empty
         # strings as missing. jq `a // b` only skips null/false -- 0 IS kept --
         # so the missing-BPS case must be gated by an explicit presence check:
         # with no BPS tag the BPS*x product is replaced by null, which then
         # falls through to the bare DURATION-seconds rank.
         size: (($s.tags["NUMBER_OF_BYTES"] // $s.tags["NUMBER_OF_BYTES-eng"] // null | tonumber?)
                // (if (($s.tags["DURATION"] // $s.tags["DURATION-eng"] // "" | . != "")) then
                     (($s.tags["DURATION"] // $s.tags["DURATION-eng"] // "0") | split(":") | map(tonumber? // 0)) as $t
                     | (if (($s.tags["BPS"] // $s.tags["BPS-eng"] // "" | . != "")) then
                          ($t[0]*3600 + $t[1]*60 + $t[2]) * (($s.tags["BPS"] // $s.tags["BPS-eng"] // null | tonumber? // 0))
                        else null end)
                       // ($t[0]*3600 + $t[1]*60 + $t[2])
                   else null end)
                // (($s.bit_rate? // 0) * ($s.duration? // 0))
                // 0)
       })
     | sort_by(-.size)
     | first
     | .st)
  ')
  if [ -n "$ENGLISH_SUB_JSON" ] && [ "$ENGLISH_SUB_JSON" != "null" ]; then
    SUB_IDX=$(echo "$ENGLISH_SUB_JSON" | jq -r '.index')
    SUB_CODEC=$(echo "$ENGLISH_SUB_JSON" | jq -r '.codec_name')
    case "$SUB_CODEC" in
      hdmv_pgs_subtitle | dvd_subtitle | dvb_subtitle | xsub)
        echo "   [SUBTITLE]: Largest English sub is image-based ($SUB_CODEC at stream $SUB_IDX). Burning into the video."
        ESC_FILE=$(printf '%s' "$SOURCE_FILE" | sed 's/\\/\\\\/g; s/:/\\:/g; s/,/\\,/g; s/;/\\;/g; s/'"'"'/\\'"'"'/g; s/\[/\\[/g; s/\]/\\]/g; s/ /\\ /g')
        BURN_FILTER="subtitles='${ESC_FILE}':si=${SUB_IDX}"
        ;;
      *)
        echo "   [SUBTITLE]: Largest English sub is text-based ($SUB_CODEC at stream $SUB_IDX). Muxing as subrip."
        if [ "$SUB_CODEC" == "subrip" ]; then
          SUB_MAP_OPTS="-map 0:${SUB_IDX} -c:s copy -metadata:s:s:0 language=eng"
        else
          SUB_MAP_OPTS="-map 0:${SUB_IDX} -c:s subrip -metadata:s:s:0 language=eng"
        fi
        ;;
    esac
  else
    echo "   [SUBTITLE]: No English subtitle found. No subtitle tracks included, no burn."
  fi
```

Update the assembly block (Task 3's version) to append `SUB_MAP_OPTS`:

```bash
  if [ -n "$AUDIO_MAPS" ]; then COMMAND+=($AUDIO_MAPS $AUDIO_CODEC_OPTS $AUDIO_METADATA_OPTS); fi
  if [ -n "$SUB_MAP_OPTS" ]; then COMMAND+=($SUB_MAP_OPTS); fi
  COMMAND+=(-map_chapters 0 -map_metadata 0 -y "$OUTPUT_FILE_MKV")
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash -n ffmpeg/plex_conversion_script_v3.sh && bash ffmpeg/tests/verify_v3.sh ffmpeg/plex_conversion_script_v3.sh /tmp/opencode/plex-v3-work`
Expected: all `f1:`, `f5:`, `f6:`, `f7:`, and re-run `f3:` `ok:` lines pass. `f5` output must contain **zero** subtitle streams (burned) and its video is hevc (re-encoded). No external `.srt` files anywhere under `$WORK`.

Optional burn sanity check (the `subtitles` filter requires libass):

```bash
ffmpeg -y -v error -i /tmp/opencode/plex-v3-work/fixtures/f5_burn/converted/input.mkv -vf fps=1 -frames:v 1 /tmp/opencode/plex-v3-work/burncheck.png
```
Open `burncheck.png`; the "Burned English" caption should be visible.

- [ ] **Step 5: Commit**

```bash
git add ffmpeg/plex_conversion_script_v3.sh ffmpeg/tests/verify_v3.sh
git commit -m "update"
```

---

### Task 5: Full matrix, chapters, final assembly (attachments dropped)

**Files:**
- Modify: `ffmpeg/plex_conversion_script_v3.sh` (final assembly; renumber section comment to `5`)
- Modify: `ffmpeg/tests/verify_v3.sh` (full-matrix f1 asserts + attachments-dropped assert)
- Test: `ffmpeg/tests/verify_v3.sh`

**Interfaces:**
- Consumes: `COMMAND` from Tasks 2–4.
- Produces: nothing new for later tasks (final behavior). This task proves the complete pipeline.

> Attachments decision (user, 2026-08-29): **cover art AND font attachments are intentionally dropped.** Fonts are never needed — text subs are converted to subrip (no styling survives) and image subs are burned as bitmaps. The script has NO attachment section in v3.

- [ ] **Step 1: Write the failing test — full matrix + attachments dropped**

Append to `ffmpeg/tests/verify_v3.sh`:

```bash
# ---- Full matrix + attachments dropped -------------------------------
run_and_log "$F1"
[ "$(attached_count "$F1/converted/input.mkv")" = "0" ] && ok "f1: cover/fonts dropped" || fail "f1: attachments present"
[ "$(stream_count "$F1/converted/input.mkv" video)" = "1" ]    && ok "f1: matrix video"    || fail "f1: matrix video"
[ "$(stream_count "$F1/converted/input.mkv" audio)" = "1" ]    && ok "f1: matrix audio"    || fail "f1: matrix audio"
[ "$(stream_count "$F1/converted/input.mkv" subtitle)" = "1" ] && ok "f1: matrix sub"      || fail "f1: matrix sub"

# f5 burned video must survive the full pipeline
[ "$(stream_prop "$F5/converted/input.mkv" video 0 codec_name)" = "hevc" ] && ok "f5: burned video ok" || fail "f5: burned video"

# every converted file must be a matroska container
for f in "$F1/converted/input.mkv" "$F4/converted/input.mkv" "$F6/converted/input.mkv"; do
  fmt=$(probe "$f" | jq -r '.format.format_name // ""')
  case "$fmt" in *matroska*) ok "container: $(basename "$(dirname "$f")") matroska" ;; *) fail "container: $f -> $fmt" ;; esac
done

# no external .srt sidecars anywhere
SIDS=$(find "$FXD" -name 'converted' -type d | while read -r cd; do find "$cd" -name '*.srt'; done)
[ -z "$SIDS" ] && ok "no external .srt sidecars" || fail "external .srt files found: $SIDS"
```

- [ ] **Step 2: Run the test to verify the f1 assertion set passes (consolidation)**

Run: `bash ffmpeg/tests/verify_v3.sh ffmpeg/plex_conversion_script_v3.sh /tmp/opencode/plex-v3-work`
Expected: every `ok:` line passes. Task 5 is a **regression/consolidation** task — the video/audio/sub codecs already pass by Task 4, no new codec logic is introduced here, so the red phase is intentionally skipped in favor of a must-pass matrix (matches the plan's consolidated-rules TDD scope; refactoring + the TDD rhythm for the new bits already proved in Tasks 2–4).

- [ ] **Step 3: Implement final assembly (no attachments section)**

In `ffmpeg/plex_conversion_script_v3.sh`:

Replace the `# ---- 6a. Assemble and execute (video-only for THIS task) ----` label with `# ---- 5. Assemble and execute ----` and update the assembly block to its final form (note: **no** `-map 0:t`, attachments intentionally dropped):

```bash
  echo "   Building final MKV conversion command..."
  COMMAND=(ffmpeg -nostdin -hide_banner -v error -stats $HWACCEL -i "$SOURCE_FILE" -map 0:$VID_INDEX)
  COMMAND+=("${VIDEO_OPTS[@]}")
  if [ -n "$AUDIO_MAPS" ]; then COMMAND+=($AUDIO_MAPS $AUDIO_CODEC_OPTS $AUDIO_METADATA_OPTS); fi
  if [ -n "$SUB_MAP_OPTS" ]; then COMMAND+=($SUB_MAP_OPTS); fi
  COMMAND+=(-map_chapters 0 -map_metadata 0 -y "$OUTPUT_FILE_MKV")
```

Add the execute + failure-handling block at the end of the loop body:

```bash
  echo "   Executing: ${COMMAND[*]}"
  if "${COMMAND[@]}"; then
    echo "   SUCCESS: MKV file created successfully."
  else
    ANY_FAIL=$((ANY_FAIL + 1))
    echo "   !! FFMPEG ERROR: MKV conversion failed (partial output removed)." >&2
    rm -f "$OUTPUT_FILE_MKV"
  fi
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash -n ffmpeg/plex_conversion_script_v3.sh && bash ffmpeg/tests/verify_v3.sh ffmpeg/plex_conversion_script_v3.sh /tmp/opencode/plex-v3-work`
Expected: every `ok:` line passes, zero `FAIL:` lines, exit 0.

- [ ] **Step 5: Commit**

```bash
git add ffmpeg/plex_conversion_script_v3.sh ffmpeg/tests/verify_v3.sh
git commit -m "update"
```

---

### Task 6: Acceptance run, docs, and final verification

**Files:**
- Modify: `ffmpeg/plex_script_notes.md` (document v3; replace v2-only claims)
- Read/Test: `ffmpeg/tests/verify_v3.sh` full run; manual runs against both proven samples (Crushology, Kaiju).

- [ ] **Step 1: Document v3 in `plex_script_notes.md`**

Update the AGENTS-style doc so it describes v3 (keep hardware facts and the Plex "Maximum H.264 Level" note). Replace the codec-decision sections with:

```markdown
## v3: Proven Direct-Play Target (Samsung TV)

Two files are empirically proven to direct-play on the target TV with zero
transcoding: a Crushology H.264 sample and a Kaiju HEVC Main 10 sample.
v3 copies any stream at-or-below this ceiling and normalizes only what
exceeds it.

| Stream | Proven copy ceiling |
|--------|---------------------|
| Video  | h264/yuv420p OR hevc/yuv420p|yuv420p10le, <=1920x1088, <=30 fps |
| Audio  | aac stereo ANY sample rate (44.1k/48k proven) |
| Subs   | Largest English only: text -> muxed subrip; image -> burned into video |
| Name   | Output name strips `[...]` and `(...)` groups (brackets/parens + contents), collapses whitespace |
| Extras | Cover art + font attachments DROPPED (Plex uses its own poster); chapters + format metadata preserved |

### Video
- COPY iff (h264 & yuv420p) or (hevc & yuv420p10le<=10bit), <=1920x1088,
  <=30fps, and no pending burn.
- Else re-encode to HEVC Main 10 (yuv420p10le) <=1080p <=30fps.
- Filter chain (resize / fps cap / burn) => CPU libx265 (subtitles filter
  cannot run on CUDA frames). No filter chain => hevc_nvenc when available.

### Audio
- KOR, JPN, ENG only, priority KOR -> JPN -> ENG; others dropped (fallback
  to first audio track if none match).
- COPY iff aac + stereo, ANY sample rate. Else aac 192k stereo 48k
  (5.1+ downmixed, mono/odd layouts upmixed).

### Subtitles (English-only, one track)
- Largest English sub by size: NUMBER_OF_BYTES -> BPS*DURATION -> DURATION alone -> bit_rate*duration.
- Text (subrip/ass/ssa/webvtt) -> muxed embedded as subrip (no sidecars).
- Image (PGS/VobSub/DVB) -> burned into the video via the `subtitles` filter.
- No English subtitle -> no tracks, no burn.

### Attachments / container
- Attachments intentionally DROPPED (cover art + fonts; see Global Constraint #7);
  `-map_chapters 0`; `-map_metadata 0`; output always MKV in `converted/`.
- Output name: `[..]` and `(..)` groups stripped from the input basename,
  whitespace collapsed/trimmed (e.g. `[Purple] JUJUTSU KAISEN - S03E01 (BD
  1080p HEVC Opus 2.0).mkv` -> `JUJUTSU KAISEN - S03E01.mkv`).
```

Keep the "Key Learnings" and "Current Machine Hardware" sections (adjust the NVENC section: detection now keyed on `hevc_nvenc`; `h264_nvenc` no longer used by v3).

- [ ] **Step 2: Full test suite + shellcheck**

Run: `bash -n ffmpeg/plex_conversion_script_v3.sh && shellcheck -S warning ffmpeg/plex_conversion_script_v3.sh && bash -n ffmpeg/tests/*.sh`
Then run: `bash ffmpeg/tests/verify_v3.sh ffmpeg/plex_conversion_script_v3.sh /tmp/opencode/plex-v3-work`
Expected: all `ok:` lines, zero `FAIL:`, exit 0; `shellcheck` (if installed) reports no `error`-level findings that the step must fix.

- [ ] **Step 3: Acceptance runs on the two proven samples**

```bash
mkdir -p /tmp/opencode/accept1 /tmp/opencode/accept2
cp "$SRC_Crushology.mkv" /tmp/opencode/accept1/
cp "$SRC_Kaiju.mkv"      /tmp/opencode/accept2/
bash ffmpeg/plex_conversion_script_v3.sh /tmp/opencode/accept1
bash ffmpeg/plex_conversion_script_v3.sh /tmp/opencode/accept2
```

Verify with `ffprobe`:
- **Crushology output:** video h264/yuv420p/1920x1080/30fps **copied**; audio kor aac 48k stereo **copied**; exactly one eng subrip muxed; SPA/POR dropped (confirmed expected); **0 attached pictures** (cover art intentionally dropped).
- **Kaiju output:** video hevc/`yuv420p10le`/1920x1080/~23.81fps **copied** (this is now the headline case: no codec change); audio jpn aac 48k stereo **copied**; audio eng aac **44.1kHz stereo copied**; all 4 chapters present; no subtitle streams (none in source); no attachment.

Then play both outputs on the TV via Plex and confirm no transcode.

- [ ] **Step 4: Final verify + commit**

Re-run the full harness once more, then:

```bash
git add ffmpeg/plex_conversion_script_v3.sh ffmpeg/tests ffmpeg/plex_script_notes.md
git commit -m "update"
```

- [ ] **Step 5: Self-review the completed work against the spec**

Re-read Step 3's output and confirm each Global Constraint (#1–#11) holds on both real samples: HEVC Main 10 and 44.1kHz audio copy untouched, chapters + metadata intact, **cover art + font attachments dropped (0 attached pictures in output)**, failure handling (exit 1 on error, partial output removed, non-empty skip), MKV container, `[..]`/`(..)`-cleaned output file names, no `.srt` sidecars, and the Plex "Maximum H.264 Level" note still documented.

---

## Phase 2 (2026-08-30): GPU-guaranteed encoding + subtitle cleanup backport

**Why:** All of Task 1's "encoder detection" was dead on arrival. The `ffmpeg -hide_banner -encoders | grep -q` pattern under `set -o pipefail` (Global Constraint #12) always evaluated false, so `NVENC_HEVC=0 HAS_LIBX265=0` on every real run — re-encodes silently fell to CPU `libx264` even though the RTX 4060 and `hevc_nvenc` were present (nvidia-smi OK, `ffmpeg -encoders` shows `V....D hevc_nvenc`). Verified: 10/10 pipefail runs MISS, 10/10 non-pipefail runs FOUND; NVENC smoke-encodes work end-to-end (`Video: hevc (Main 10), yuv420p10le, 1920x1080` with 884 MiB VRAM in use). Phase 2 also reverts the v3 subtitle regression (Task 4's inline `-c:s subrip` leaks ASS/HTML/draw text into the embedded track — v2's cleanup sed is missing in v3) and adds auto-deinterlace + `--dry-run` + post-encode verify. **Only v3 changes.**

**Files:**
- Modify: `ffmpeg/plex_conversion_script_v3.sh`
- Create: `ffmpeg/tests/simulate_gpu.sh` — random-sampling harness that dry-runs v3 over sampled real library files and asserts GPU usage
- Modify: `ffmpeg/plex_script_notes.md` — fold finalized GPU/subtitle behavior into the doc

---

### Task 7: Fix encoder detection (SIGPIPE/pipefail) + startup instrumentation

**Files:**
- Modify: `ffmpeg/plex_conversion_script_v3.sh:11-22` (detection), and the loop guard at `:45`
- Test: `bash -n`; a standalone replica of the new detection block printed under `bash -c` must report `NVENC_HEVC=1 HAS_LIBX265=1 HAS_CUDA_HWACCEL=1` on this machine

- [x] **Step 1: Write the failing check (replica of the OLD detection)**

Run:
```bash
bash -c 'set -euo pipefail
NVENC_HEVC=0; HAS_LIBX265=0
if nvidia-smi &>/dev/null; then if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q hevc_nvenc; then NVENC_HEVC=1; fi; fi
if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q libx265; then HAS_LIBX265=1; fi
echo "OLD: NVENC_HEVC=$NVENC_HEVC HAS_LIBX265=$HAS_LIBX265"'
```
Expected: `NVENC_HEVC=0 HAS_LIBX265=0` (the bug, reproduced).

- [x] **Step 2: Write the passing check (the NEW detection)**

Run:
```bash
bash -c 'set -euo pipefail
NVENC_HEVC=0; HAS_LIBX265=0; HAS_CUDA_HWACCEL=0
FFMPEG_BIN=$(command -v ffmpeg)
ENCODER_LIST=$(ffmpeg -hide_banner -encoders 2>/dev/null || true)
HWACCEL_LIST=$(ffmpeg -hide_banner -hwaccels 2>/dev/null || true)
[[ "$ENCODER_LIST" == *hevc_nvenc* ]] && NVENC_HEVC=1
[[ "$ENCODER_LIST" == *libx265* ]] && HAS_LIBX265=1
[[ "$HWACCEL_LIST" == *cuda* ]] && HAS_CUDA_HWACCEL=1
echo "NEW: NVENC_HEVC=$NVENC_HEVC HAS_LIBX265=$HAS_LIBX265 HAS_CUDA_HWACCEL=$HAS_CUDA_HWACCEL"'
```
Expected: `NVENC_HEVC=1 HAS_LIBX265=1 HAS_CUDA_HWACCEL=1` (proves the string-match is immune to the SIGPIPE race).

- [x] **Step 3: Implement in v3**

Replace `ffmpeg/plex_conversion_script_v3.sh:11-22` with:

```bash
# --- Encoder detection (NVENC HEVC + software x265) ---
# 2026-08-30: capture the lists once and string-match. The old
# `ffmpeg --encoders | grep -q` pattern always failed under set -o pipefail:
# grep -q exits on its first match -> ffmpeg got SIGPIPE -> pipeline reported
# 141 -> NVENC_HEVC/HAS_LIBX265 were ALWAYS 0 -> every re-encode used CPU libx264.
NVENC_HEVC=0
HAS_LIBX265=0
HAS_CUDA_HWACCEL=0
FFMPEG_BIN=$(command -v ffmpeg)
ENCODER_LIST=$(ffmpeg -hide_banner -encoders 2>/dev/null || true)
HWACCEL_LIST=$(ffmpeg -hide_banner -hwaccels 2>/dev/null || true)
[[ "$ENCODER_LIST" == *hevc_nvenc* ]] && NVENC_HEVC=1
[[ "$ENCODER_LIST" == *libx265* ]] && HAS_LIBX265=1
[[ "$HWACCEL_LIST" == *cuda* ]] && HAS_CUDA_HWACCEL=1

GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || true)
echo "[ENCODER] ffmpeg=$FFMPEG_BIN nvidia='${GPU_NAME:-none}' hevc_nvenc=$NVENC_HEVC cuda_hwaccel=$HAS_CUDA_HWACCEL libx265=$HAS_LIBX265"
if (( NVENC_HEVC )) && (( HAS_CUDA_HWACCEL )); then
  echo "   -> GPU HEVC encoding selected (hevc_nvenc + cuda hwaccel): re-encodes use the NVIDIA GPU."
elif (( NVENC_HEVC )); then
  echo "   -> hevc_nvenc available but cuda hwaccel missing (still GPU encode; CPU decode)."
elif (( HAS_LIBX265 )); then
  echo "   !! WARNING: hevc_nvenc NOT available. Re-encodes will use CPU libx265 (GPU NOT used)." >&2
else
  echo "   !! WARNING: neither hevc_nvenc nor libx265 available. Re-encodes use CPU libx264 (GPU NOT used)." >&2
fi
```

- [x] **Step 4: Fix the loop guard (`:45`)**

Replace the guard with:

```bash
  VCODEC_TYPE=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_type "$SOURCE_FILE" 2>/dev/null || true)
  if [[ "$VCODEC_TYPE" != *codec_type=video* ]]; then
    continue
  fi
```

- [x] **Step 5: Verify**

Run: `bash -n ffmpeg/plex_conversion_script_v3.sh`
Run: `command -v shellcheck >/dev/null && shellcheck -S warning ffmpeg/plex_conversion_script_v3.sh || echo "shellcheck not installed"`
Expected: clean syntax; shellcheck (if present) reports nothing the step must fix.

- [x] **Step 6: Commit**

```bash
git add ffmpeg/plex_conversion_script_v3.sh
git commit -m "update"
```

---

### Task 8: `--dry-run` mode + post-encode verify (GPU + verify + warn)

**Files:**
- Modify: `ffmpeg/plex_conversion_script_v3.sh` (arg parsing before the usage check; assembly; execute block)

- [x] **Step 1: Add `--dry-run` arg parsing**

Insert after the detection block (before the `if [ "$#" -ne 1 ]` usage check):

```bash
DRY_RUN=0
if [ "${1:-}" == "--dry-run" ]; then
  DRY_RUN=1
  shift
fi
```

- [x] **Step 2: Guard the `converted/` mkdir (dry-run must not write)**

Change `mkdir -p "$OUTPUT_DIR"` to:

```bash
  if (( ! DRY_RUN )); then
    mkdir -p "$OUTPUT_DIR"
  fi
```

- [x] **Step 3: Split execute vs dry-run + add verify**

Inside the loop body (rename `# ---- 5. Assemble and execute ----` to `# ---- 5. Assemble, execute & verify ----`), replace the execute block with:

```bash
  echo "   Executing: ${COMMAND[*]}"
  if (( DRY_RUN )); then
    echo "   [DRY-RUN]: command shown only; execution skipped."
  else
    if "${COMMAND[@]}"; then
      echo "   SUCCESS: MKV file created successfully."
      OUT_CODEC=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=nokey=1:noprint_wrappers=1 "$OUTPUT_FILE_MKV" 2>/dev/null || true)
      if [ -z "$OUT_CODEC" ]; then
        ANY_FAIL=$((ANY_FAIL + 1))
        echo "   !! VERIFY ERROR: could not read output; removing." >&2
        rm -f "$OUTPUT_FILE_MKV"
      elif [ "$OUT_CODEC" == "$CODEC" ] && (( COPIES_VIDEO )); then
        echo "   [VERIFY]: output video copied as $CODEC. OK."
      elif [ "$OUT_CODEC" == "hevc" ]; then
        echo "   [VERIFY]: output video re-encoded to HEVC. OK."
      else
        ANY_FAIL=$((ANY_FAIL + 1))
        echo "   !! VERIFY ERROR: expected output codec $CODEC (copy) or hevc (re-encode) but got '$OUT_CODEC'. Removing." >&2
        rm -f "$OUTPUT_FILE_MKV"
      fi
    else
      ANY_FAIL=$((ANY_FAIL + 1))
      echo "   !! FFMPEG ERROR: MKV conversion failed (partial output removed)." >&2
      rm -f "$OUTPUT_FILE_MKV"
    fi
    if [ -n "$TMP_SRT_FILE" ]; then
      rm -f "$TMP_SRT_FILE"
    fi
  fi
```

- [x] **Step 4: Initialize per-loop variables**

At the top of the loop body (after `start_time_human=...`), add:

```bash
  COPIES_VIDEO=0
  ADD_SRT_INPUT=0
  TMP_SRT_FILE=""
```

- [x] **Step 5: Verify**

Run: `bash -n ffmpeg/plex_conversion_script_v3.sh`
Expected: clean. (Full dry-run behavior is asserted in Task 11.)

---

### Task 9: NVENC-favoring video decision + auto-deinterlace

**Files:**
- Modify: `ffmpeg/plex_conversion_script_v3.sh` (video-decision block `:139-195`)

- [x] **Step 1: Add interlace detection + NVENC / deinterlace logic**

Replace the video-decision block (`# ---- 3. Video decision ----` … the closing `fi` before `# ---- 4. Audio decision ----`) with:

```bash
  # ---- 3. Video decision ----
  # Proven copy ceiling: h264/yuv420p OR hevc/yuv420p|yuv420p10le, <=1920x1088,
  # <=30fps, no burn, AND progressive. Anything else -> re-encode.
  # 2026-08-30: re-encodes ALWAYS prefer hevc_nvenc (GPU). With a filter chain
  # (deinterlace/resize/fps/burn) NVENC runs WITHOUT -hwaccel cuda: filters run on
  # CPU frames, the encode still happens on the GPU. CPU libx265 is only a failsafe.
  VIDEO_FILTERS=""
  VIDEO_OPTS=()
  HWACCEL=""
  NVENC_OPTS=(-c:v hevc_nvenc -preset p7 -tune hq -cq 27 -rc vbr -multipass 1 -b_ref_mode middle -bf 4 -spatial-aq 1 -temporal-aq 1 -rc-lookahead 32 -pix_fmt yuv420p10le)
  SAFE_VIDEO=0
  case "$CODEC" in
    h264)
      if [ "$PIX_FMT" == "yuv420p" ] && (( WIDTH <= 1920 )) && (( HEIGHT <= 1088 )) && (( FPS_INT <= 30 )); then
        SAFE_VIDEO=1
      fi
      ;;
    hevc)
      if { [ "$PIX_FMT" == "yuv420p" ] || [ "$PIX_FMT" == "yuv420p10le" ]; } \
            && (( WIDTH <= 1920 )) && (( HEIGHT <= 1088 )) && (( FPS_INT <= 30 )); then
        SAFE_VIDEO=1
      fi
      ;;
  esac

  FIELD_ORDER=$(echo "$VIDEO_STREAM_JSON" | jq -r '.field_order // "progressive"')
  INTERLACED=0
  case "$FIELD_ORDER" in
    progressive | unknown) ;;
    *) INTERLACED=1 ;;
  esac

  if (( SAFE_VIDEO )) && [ -z "${BURN_FILTER:-}" ] && (( ! INTERLACED )); then
    echo "   [VIDEO]: Proven-compatible (${CODEC}, ${WIDTH}x${HEIGHT}, ${PIX_FMT}, ${FPS_DEC} fps, progressive). Copying stream."
    COPIES_VIDEO=1
    VIDEO_OPTS=(-c:v copy)
  else
    echo "   [VIDEO]: Needs re-encode (${CODEC}, ${WIDTH}x${HEIGHT}, ${PIX_FMT}, ${FPS_DEC} fps, field=${FIELD_ORDER}, burn=$(if [ -n "${BURN_FILTER:-}" ]; then echo yes; else echo no; fi))."
    if (( INTERLACED )); then
      VIDEO_FILTERS+="yadif"
    fi
    if (( WIDTH > 1920 )) || (( HEIGHT > 1088 )); then
      [ -n "$VIDEO_FILTERS" ] && VIDEO_FILTERS+=","
      VIDEO_FILTERS+="scale=1920:1080:force_original_aspect_ratio=decrease:flags=lanczos,scale=trunc(iw/2)*2:trunc(ih/2)*2,setsar=1"
    fi
    if (( FPS_INT > 30 )); then
      [ -n "$VIDEO_FILTERS" ] && VIDEO_FILTERS+=","
      VIDEO_FILTERS+="fps=30"
    fi
    if [ -n "${BURN_FILTER:-}" ]; then
      [ -n "$VIDEO_FILTERS" ] && VIDEO_FILTERS+=","
      VIDEO_FILTERS+="$BURN_FILTER"
    fi

    if (( NVENC_HEVC )); then
      if [ -n "$VIDEO_FILTERS" ]; then
        echo "   [VIDEO]: Re-encoding via NVENC HEVC (filter chain: $VIDEO_FILTERS)."
        VIDEO_OPTS=("${NVENC_OPTS[@]}" -vf "$VIDEO_FILTERS")
      else
        echo "   [VIDEO]: Re-encoding via NVENC HEVC (GPU decode+encode, no filter chain)."
        HWACCEL="-hwaccel cuda -hwaccel_output_format cuda"
        VIDEO_OPTS=("${NVENC_OPTS[@]}")
      fi
    elif (( HAS_LIBX265 )); then
      echo "   !! WARNING: hevc_nvenc unavailable — re-encoding via CPU libx265 (GPU NOT used)." >&2
      if [ -n "$VIDEO_FILTERS" ]; then
        VIDEO_OPTS=(-c:v libx265 -preset medium -crf 22 -pix_fmt yuv420p10le -vf "$VIDEO_FILTERS")
      else
        VIDEO_OPTS=(-c:v libx265 -preset medium -crf 22 -pix_fmt yuv420p10le)
      fi
    else
      echo "   !! WARNING: neither hevc_nvenc nor libx265 — re-encoding via CPU libx264 (GPU NOT used)." >&2
      if [ -n "$VIDEO_FILTERS" ]; then
        VIDEO_OPTS=(-c:v libx264 -preset medium -crf 19 -pix_fmt yuv420p -vf "$VIDEO_FILTERS")
      else
        VIDEO_OPTS=(-c:v libx264 -preset medium -crf 19 -pix_fmt yuv420p)
      fi
    fi
  fi
```

- [x] **Step 2: Verify option combos actually encode (direct ffmpeg smoke tests, NOT the script)**

```bash
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
# A. no-filter NVENC path (proven) + 10-bit output
timeout 60 ffmpeg -v error -y -hwaccel cuda -hwaccel_output_format cuda \
  -f lavfi -i "testsrc2=size=640x360:rate=24" -t 1 \
  -c:v hevc_nvenc -preset p7 -tune hq -cq 27 -pix_fmt yuv420p10le -f matroska /dev/null
# B. NVENC with a CPU filter chain: deinterlace+scale+fps (no hwaccel)
timeout 60 ffmpeg -v error -y -f lavfi -i "testsrc2=size=1280x720:rate=60" -t 1 \
  -vf "yadif,scale=1280:720:force_original_aspect_ratio=decrease:flags=lanczos,scale=trunc(iw/2)*2:trunc(ih/2)*2,setsar=1,fps=30" \
  -c:v hevc_nvenc -preset p7 -tune hq -cq 27 -pix_fmt yuv420p10le -f matroska /dev/null
# C. NVENC with a subtitle burn filter (path used for PGS/BDRip burns)
timeout 60 ffmpeg -v error -y -f lavfi -i "testsrc2=size=640x360:rate=24" -t 1 \
  -vf "subtitles=/dev/null:si=1" -c:v hevc_nvenc -preset p7 -cq 27 -pix_fmt yuv420p10le -f matroska /dev/null \
  || true   # /dev/null:si is a negative sanity probe; real burns tested in Task 10
```
Expected: A and B exit 0 with no error output (real burn validity is covered by Task 10's fixture; C is a soft probe).

- [x] **Step 3: Commit**

```bash
git add ffmpeg/plex_conversion_script_v3.sh
git commit -m "update"
```

---

### Task 10: Two-pass subtitle cleanup (subrip conversion) + remux

**Files:**
- Modify: `ffmpeg/plex_conversion_script_v3.sh` (subtitle text-based branch `:108-115`; assembly `:256-260`)

**Design:** `-c:s subrip` inline leaks ASS styling into the embedded track (v2 lesson; ffmpeg emits `<font size="40">`, `{\an8}`, literal `\h`, and draw coordinates as raw text). Instead: pass 1 extracts the text sub with the v2 cleanup sed (extended with a mid-line draw rule) to a temp SRT; pass 2 remuxes it via `-i <tmp.srt> -map 1:0 -c:s subrip`. Temp SRT is removed on success AND failure; on extraction failure the subs are dropped (video still proceeds). Native `subrip` keeps `-c:s copy`.

- [x] **Step 1: Implement the branch**

Replace the `*)` branch (lines `108-115`) with:

```bash
      *)
        echo "   [SUBTITLE]: Largest English sub is text-based ($SUB_CODEC at stream $SUB_IDX). Muxing as subrip."
        if [ "$SUB_CODEC" == "subrip" ]; then
          SUB_MAP_OPTS="-map 0:${SUB_IDX} -c:s copy -metadata:s:s:0 language=eng"
        else
          TMP_SRT_FILE="$OUTPUT_DIR/.${FILE_NAME_NO_EXT}.sub.$$.srt"
          if (( DRY_RUN )); then
            echo "   [SUBTITLE]: (dry-run) would extract+clean $SUB_CODEC -> temp SRT -> subrip."
            SUB_MAP_OPTS="-map 1:0 -c:s subrip -metadata:s:s:0 language=eng"
            ADD_SRT_INPUT=1
          else
            set +o pipefail
            ffmpeg -nostdin -hide_banner -v error -i "$SOURCE_FILE" -map "0:${SUB_IDX}" -f srt - 2>"$OUTPUT_DIR/.${FILE_NAME_NO_EXT}.srt.err.$$" |
              sed -E '
                  s/\{[^}]*\}//g
                  s/<[^>]*>//g
                  s/\\h/ /g
                  s/\\[nN]/ /g
                   /(^|[[:space:]])[mnlbscp][[:space:]]+-?[0-9]+(\.[0-9]+)?[[:space:]]+-?[0-9]+(\.[0-9]+)?/d
                ' >"$TMP_SRT_FILE"
            srt_exit=${PIPESTATUS[0]}
            set -o pipefail
            rm -f "$OUTPUT_DIR/.${FILE_NAME_NO_EXT}.srt.err.$$"
            if (( srt_exit != 0 )); then
              echo "   [WARN] SRT extraction failed at stream $SUB_IDX (ffmpeg exit $srt_exit). Dropping subtitles." >&2
              rm -f "$TMP_SRT_FILE"
              TMP_SRT_FILE=""
            elif [ ! -s "$TMP_SRT_FILE" ]; then
              echo "   [WARN] SRT extraction produced an empty file at stream $SUB_IDX. Dropping subtitles." >&2
              rm -f "$TMP_SRT_FILE"
              TMP_SRT_FILE=""
            else
              echo "   [SUBTITLE]: cleaned SRT extracted to temp for remux."
              SUB_MAP_OPTS="-map 1:0 -c:s subrip -metadata:s:s:0 language=eng"
              ADD_SRT_INPUT=1
            fi
          fi
        fi
        ;;
```

- [x] **Step 2: Wire the second input into assembly**

Change the command build to:

```bash
  echo "   Building final MKV conversion command..."
  COMMAND=(ffmpeg -nostdin -hide_banner -v error -stats $HWACCEL -i "$SOURCE_FILE")
  if (( ADD_SRT_INPUT )) && [ -n "$TMP_SRT_FILE" ]; then
    COMMAND+=(-i "$TMP_SRT_FILE")
  fi
  COMMAND+=(-map 0:$VID_INDEX)
  COMMAND+=("${VIDEO_OPTS[@]}")
  if [ -n "$AUDIO_MAPS" ]; then COMMAND+=($AUDIO_MAPS $AUDIO_CODEC_OPTS $AUDIO_METADATA_OPTS); fi
  if [ -n "$SUB_MAP_OPTS" ]; then COMMAND+=($SUB_MAP_OPTS); fi
  COMMAND+=(-map_chapters 0 -map_metadata 0 -y "$OUTPUT_FILE_MKV")
```

- [x] **Step 3: Validate the sed + remux combo (direct ffmpeg, NOT the script)**

```bash
W=$(mktemp -d)
printf '1\n00:00:00,000 --> 00:00:01,000\n{\\an8}\\N<b>Bold</b> line\\hzero 5.0 10\n' > "$W/x.ass"
ffmpeg -v error -y -f lavfi -i "color=c=blue:size=320x180:rate=24" -t 1 \
  -vf "subtitles=$W/x.ass" -an "$W/base.mkv"
# put a styled ASS into the container, then run v3's exact extraction+sed:
ffmpeg -v error -y -i "$W/base.mkv" -vf "subtitles=$W/x.ass" -an \
  -c:v libx265 -preset ultrafast -tag:v hvc1 -f matroska "$W/src.mkv"
# (src.mkv has burned text; NOT what v3 does — see note) -> instead just verify sed
printf 'some text m 0 0 100 5.0\nx {\an8}<font size="40">\h val\n' | sed -E '
    s/\{[^}]*\}//g
    s/<[^>]*>//g
    s/\\h/ /g
    s/\\[nN]/ /g
     /(^|[[:space:]])[mnlbscp][[:space:]]+-?[0-9]+(\.[0-9]+)?[[:space:]]+-?[0-9]+(\.[0-9]+)?/d
  '
printf -- '---\nstore this line\n'
# expected output: first line deleted (leading draw cmd), second line -> "x  val", "store this line" kept
rm -rf "$W"
```
Expected: the printed stream is exactly `x  val` then `store this line` — the draw-command line deleted and the mid-line `{\an8}`/`<font ...>`/`\h` stripped.

- [x] **Step 4: Commit**

```bash
git add ffmpeg/plex_conversion_script_v3.sh
git commit -m "update"
```

---

### Task 11: GPU random-sampling harness + full verification + docs + commit

**Files:**
- Create: `ffmpeg/tests/simulate_gpu.sh`
- Modify: `ffmpeg/plex_script_notes.md`
- Test: run the harness over real library files (never executing conversions — `--dry-run` only) plus `bash -n` + `shellcheck`

- [x] **Step 1: Write the harness**

Create `ffmpeg/tests/simulate_gpu.sh`:

```bash
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
# deterministic sampling (fixed seed 2026); awk RNG
idx=$(awk -v n="$N" -v c="$c" 'BEGIN{srand(2026); for(i=0;i<c;i++){r=int(rand()*n); while(seen[r]++) r=int(rand()*n); if(sep)printf " "; printf "%d", r; sep=1}}')
i=0
for k in $idx; do
  i=$((i + 1))
  base=$(basename "${FILES[$k]}")
  ln -sf "${FILES[$k]}" "$SAMPLE/$(printf '%02d - %s' "$i" "$base")"
done

bash "$V3" --dry-run "$SAMPLE" > "$WORK/run.log" 2>&1

# 1. startup encoder matrix + GPU selection
grep -q '\[ENCODER\]' "$WORK/run.log" && ok "startup encoder matrix printed" || fail "missing [ENCODER] line"
grep -q 'GPU HEVC encoding selected' "$WORK/run.log" && ok "GPU HEVC selected" || fail "GPU HEVC NOT selected (see log)"

# 2. every re-encode decision must be NVENC HEVC (GPU); zero CPU fallbacks
REENC=$(grep -c 'Needs re-encode' "$WORK/run.log" || true)
NVENC=$(grep -c 'Re-encoding via NVENC HEVC' "$WORK/run.log" || true)
CPU=$(grep -c 'CPU libx' "$WORK/run.log" || true)
grep -q 'hevc_nvenc' "$WORK/run.log" && ok "assembled commands reference hevc_nvenc" || fail "no hevc_nvenc in any command"
if [ "$NVENC" -eq "$REENC" ]; then ok "GPU used for $NVENC/$REENC re-encode decisions"; else fail "GPU used for $NVENC/$REENC re-encode decisions"; fi
[ "$CPU" -eq 0 ] && ok "zero CPU re-encode decisions" || fail "$CPU CPU re-encode decision(s) (warnings require failsafe path)"

# 3. no libx264 anywhere
grep -q 'libx264 (no libx265)' "$WORK/run.log" && fail "libx264 fallback still reachable in decision log" || ok "no libx264 decision"

# 4. dry-run wrote nothing: no converted/ outputs, no conversion ran
OUTS=$(find "$SAMPLE" -name '*.mkv' -newer "$WORK/run.log" | wc -l)
[ "$OUTS" -eq 0 ] && ok "dry-run produced no output files" || fail "$OUTS output file(s) appeared"

echo "---"
echo "Re-encode decisions: $REENC | NVENC: $NVENC | CPU-libx: $CPU"
if [ "$FAILS" -gt 0 ]; then echo "RTL: $FAILS failure(s)" >&2; exit 1; fi
echo "RTL: all GPU checks passed."
```

- [x] **Step 2: Run it against the real library**

```bash
bash ffmpeg/tests/simulate_gpu.sh \
  ffmpeg/plex_conversion_script_v3.sh /tmp/opencode/plex-v3-gpu /mnt/dorneMedia/Pinoy 10
```
Expected: `ok:` lines for every assert; `RTL: all GPU checks passed.`; re-encode decisions all `Re-encoding via NVENC HEVC`. Run at least 3 draws (change the rooths to the JJK S01 / S03 BD folders too) to exercise BDRip AVC + HEVC + AV1 inputs.

- [x] **Step 3: Full static checks**

```bash
bash -n ffmpeg/plex_conversion_script_v3.sh
command -v shellcheck >/dev/null && shellcheck -S warning ffmpeg/plex_conversion_script_v3.sh ffmpeg/tests/simulate_gpu.sh || echo "shellcheck not installed"
```
Expected: clean.

- [x] **Step 4: Update `plex_script_notes.md`**

Remove the stale "grep encoders with `ffmpeg -hide_banner -encoders`" note (superseded by the string-match rule). Add to the Key Learnings section:

```markdown
### 2026-08-30: GPU-guaranteed encoding + subtitle backport (v3)
- **`set -o pipefail` + `grep -q` over a producer is a silent failure.** grep
  exits on the first match, the still-writing ffmpeg/ffprobe takes SIGPIPE,
  and pipefail reports the pipeline failed — so the `if` never fires. This
  disabled NVENC detection in EVERY script version (hevc_nvenc/libx265 always
  reported missing; re-encodes silently used CPU libx264). Capture the output
  into a variable once and string-match (`[[ "$OUT" == *hevc_nvenc* ]]`).
- **NVENC now wins every re-encode**, including filter chains: CPU-decode +
  CPU-filters + GPU-encode (`hevc_nvenc -vf <chain>` without `-hwaccel cuda`).
  Only missing `hevc_nvenc` drops to CPU libx265, with a loud warning.
- **Post-encode verification:** every output's `v:0` codec is asserted with
  ffprobe — re-encode => hevc, copy => source codec. Mismatches are deleted
  and counted as errors.
- **Auto-deinterlace:** interlaced `field_order` (tt/bb/tb/bt) prepends `yadif`.
- **Text sub conversion is two-pass again:** ASS/etc are extracted to a temp
  SRT, cleaned with the v2 sed (now also killing mid-line draw commands), and
  remuxed via a second input; the temp SRT is deleted on success and failure.
- **`--dry-run`**: prints the encoder matrix + per-file decisions + the exact
  ffmpeg command with no conversion. Use `ffmpeg/tests/simulate_gpu.sh` to
  sample real files and assert the GPU is selected.
```

- [x] **Step 5: Final verify + commit**

```bash
git add ffmpeg/plex_conversion_script_v3.sh ffmpeg/tests/simulate_gpu.sh ffmpeg/plex_script_notes.md
git commit -m "update"
```

***Note on real-run acceptance:*** the actual library conversion is still left
to the user (never executed from here). The user deletes any stale
`converted/` dirs before re-running; after a real run, spot-check a burned
PGS file and a BDRIp-HEVC file with `ffprobe` for `hevc`, and confirm the
`[VERIFY]` lines.

---

## Task 6 verification records (addendum, 2026-08-30)

**Round-2 sampling (seed 987, 14 fresh files q01–q14):** 6 video copies / 8
re-encodes (7 NVENC + 1 CPU libx265 for the q10 PGS-burn), 4 audio copies,
all subtitle handling as designed. **IMPORTANT correction:** these simulated
traces assumed the Task-1 detection worked. Phase 2 proved it never did
(Global Constraint #12): on real runs every re-encode was in fact CPU
`libx264`. Re-run the acceptance records after Phase 2 lands. New observation
from the round: stream titled "Japanese (Crunchyroll)" but tagged `lang=eng`
is kept/copied as English — tag-beats-title, by design.

**Spec coverage:** Every decision from the approved design maps to a task — proven copy ceiling for h264+HEVC incl. `yuv420p10le` and any-rate/any-bitrate aac stereo (Task 2/3), KOR/JPN/ENG selection + fallback (Task 3), largest-English one-track subtitle rule + burn + English-only (Task 4), full matrix + chapters + final assembly with **attachments deliberately dropped** (Task 5), acceptance runs against BOTH proven samples + docs (Task 6). Fixtures exercise every branch: f1 copy-mirror, f1b 44.1k/320k stereo copy, f2 mpeg2→HEVC10 normalize, f3 fps cap, f3b resize, f4 ac3 5.1→aac stereo, f5 PGS burn, f6 no-English, f7 ass→subrip, f8 `[..]`/`(..)`-bracketed filename→cleaned output name.

**Placeholder scan:** No TBD/TODO in delivered code; the only `[TODO]` is the Task-1 scaffold placeholder that Tasks 2–5 explicitly replace. Every code step has concrete content. The Task-1 scaffold build-out for failure handling (process substitution loop, `ANY_FAIL`, non-empty skip, partial-output cleanup) supersedes the v2 bare-pipeline behavior.

**Type consistency:** `JSON_PROBE`, `VID_INDEX`, `VIDEO_OPTS` (array), `VIDEO_FILTERS`/`HWACCEL` (strings), `AUDIO_MAPS/CODEC_OPTS/METADATA_OPTS`, `SUB_MAP_OPTS`, `BURN_FILTER`, `ANY_FAIL` (int) are created once and consumed by the sections/steps that use them; `BURN_FILTER` is produced in Task 4 and consumed in Task 2's block (already read via `${BURN_FILTER:-}`, so ordering is safe). `NVENC_HEVC`/`HAS_LIBX265` flags are set in Task 1 and consumed in Task 2. `stream_count`/`stream_prop`/`attached_count`/`run_and_log` signatures are stable across harness edits; fixture dir names (`f1_sample`, `f2_codec`, `f3_fps`, `f3b_res`, `f4_ac3`, `f5_burn`, `f6_noeng`, `f7_ass`, `f8_brackets`) match between `make_fixtures.sh` and `verify_v3.sh`.

**Phase 2 review:** every 2026-08-30 decision maps to a task — SIGPIPE/pipefail detection fix + instrumentation (Global Constraint #12, Task 7), `--dry-run` + post-encode verify (Task 8), NVENC-favoring re-encode incl. burn/filter chains + auto-deinterlace (Task 9), two-pass sub cleanup with the v2 sed + mid-line draw rule + temp cleanup on both paths (Task 10), GPU random-sampling harness over real library files (Task 11). The guard-`continue` at line 45 gets the same variable-capture treatment (Task 7 Step 4). `COPIES_VIDEO`/`ADD_SRT_INPUT`/`TMP_SRT_FILE` are initialized per loop (Task 8 Step 4) and consumed by the verify/assembly blocks. The harness relies on `--dry-run` never executing a conversion (guards `mkdir` and the sub extraction), so forwarding the user's "never run the actual script" constraint. v1/v2/iphone scripts are intentionally left untouched (user decision).