# AGENTS.md — Plex Conversion Script

## One True Goal

Convert any video file for **guaranteed direct play** on Samsung (2018+, Tizen) and LG (2021+, WebOS) Plex clients with **zero server-side transcoding**. The script copies every stream the TV can natively decode and re-encodes only what it can't.

## How It Works (Step by Step)

### 1. Pre-flight
- `set -euo pipefail` — strict error handling
- Checks for `ffmpeg`, `ffprobe`, `jq`
- Detects GPU by capturing `ffmpeg -encoders` / `-hwaccels` into variables ONCE and string-matching (`[[ "$LIST" == *hevc_nvenc* ]]`). NEVER pipe to `grep -q` (see Bash key learning below — SIGPIPE/pipefail race).
- NVENC + CUDA → GPU encode, CUDA only → GPU encode with CPU decode, neither → CPU libx265 with loud warning
- Supports `--dry-run` (prints commands, never executes), validates exactly one directory argument

### 2. File Discovery
- `find` with `-name converted -prune` skips already-processed directories
- Sorts files by basename, feeds into `while read` loop

### 3. Video Decision

```
h264 + yuv420p ≤1920x1088 ≤30fps     → COPY
HEVC + yuv420p/yuv420p10le same      → COPY
HDR (color_transfer smpte2084/arib-std-b67) → NEVER copy → RE-ENCODE w/ HDR→SDR tonemap
Interlaced (field_order tt/bb/tb/bt) → NEVER copy → re-encode (prepends yadif)
Everything else (Hi10P, AV1, VP9, 12-bit HEVC, etc.) → RE-ENCODE to HEVC
```

Interlaced → never copy-eligible. HDR → never copy-eligible (even ≤1080p: an entry-level Samsung panel plays HDR too dark; the script bakes in SDR BT.709 so no tone-metadata survives). Re-encode path uses NVENC `hevc_nvenc` whenever available. No filter chain → `-hwaccel cuda -hwaccel_output_format cuda` (GPU decode+encode). With a filter chain (yadif / scale / fps / HDR tonemap) → NVENC WITHOUT hwaccel (filters run on CPU frames, encode still on GPU). libx265 / libx264 are failsafes with loud stderr warnings.

### HDR → SDR tonemap chain (separate filter path)

HDR (PQ/smpte2084 or HLG/arib-std-b67) forces a re-encode through the filter chain. The tonemap core is appended after any yadif/scale/fps:
```
zscale=t=linear:npl=100,format=gbrpf32le,tonemap=hable:desat=0,zscale=primaries=bt709:transfer=bt709,format=yuv420p10le
```
- Requisite filters in the ffmpeg build: `zscale` (libzimg) + `tonemap`. Checked once at pre-flight; if a file is HDR and they're absent → hard `[SANITY-FAIL]` skip (never silently produce the dark HDR pass-through).
- Output is tagged SDR BT.709 explicitly (`-colorspace bt709 -color_trc bt709 -color_primaries bt709 -color_range tv`) at `yuv420p10le`. Plex then shows no HDR badge and the TV's HDR mode never triggers.
- `npl=100` = 1000-nit mastering assumption (standard-good default). `desat=0` keeps color in near-white highlights.
- These re-encodes SW-decode 4K HDR on CPU (filter chain disables GPU decode) — slow but correct; only HDR files pay this cost.

### 4. Audio Decision

```
AAC / AC3 / E-AC3                                      → COPY (passthrough)
TrueHD / DTS / FLAC / Opus / Vorbis / anything else     → RE-ENCODE to AAC
  - ≥6 channels → AAC 384k 5.1
  - <6 channels → AAC 192k stereo
```

Collects ALL JPN/ENG/KOR audio tracks in priority order (KOR → JPN → ENG). Falls back to first available audio if no matching language found.

### 5. Subtitle Decision

```
PGS / DVB / VobSub / XSUB (image)    → MUXED as soft track (NOT burned; libass cannot render image subs)
ASS / SRT / SubRip (text, non-subrip) → TWO-PASS: extract→clean to temp SRT, remux as subrip
subrip (text, already SRT)            → COPY embedded
No English sub                        → dropped (no track)
```

Image subs (PGS/DVD/DVB/XSUB) are **muxed as a soft track** (`-map 0:<idx> -c:s copy`), never burned. The old burn path used the libass `subtitles` filter, which **cannot render image subtitles** — "Only text based subtitles are currently supported" at filter-graph init → the whole re-encode died. If the TV/Plex can't render PGS, Plex burns it server-side during playback instead.

Two-pass text extraction (`ffmpeg | sed`, wrapped in `set +o pipefail`): extract stream to `-f srt`, strip ASS `{\...}` override blocks and HTML tags, replace `\h` / `\N` / `\n` with spaces, delete ASS drawing command lines. Temp SRT + err file are removed on success AND failure; extraction failure drops subtitles and continues (video unaffected). The clean SRT is remuxed as subrip via a second input: `-i <temp.srt> -map 1:0 -c:s subrip`.

### 6. MKV Assembly
- Copies video (`-c:v copy`) or re-encodes
- Maps audio with per-stream codec and metadata
- Maps the clean SRT subrip via second input when a text sub was cleaned
- Outputs to `$SOURCE_DIR/converted/$FILENAME.mkv` (filename cleaned of `[..]`/`(..)` groups)
- Post-encode verify: `ffprobe` asserts output codec (re-encode → MUST be `hevc`), else deletes output + counts failure

## TV Plex Compatibility Matrix

### Samsung Tizen (2018+)

| Codec | Status | Notes |
|-------|--------|-------|
| h264 8-bit (any level) | ✅ Direct play | Set "Maximum H.264 Level" to "None" or "5.1" in Plex app |
| h264 10-bit (Hi10P) | ❌ NOT supported | Must re-encode |
| HEVC Main 10 (≤5.1) | ✅ Direct play | 10-bit supported on 2018+ |
| HEVC 12-bit | ❌ Not widely supported | Re-encode |
| AV1 | ⚠️ Hardware yes, Plex client shaky | Re-encode for safety |
| AAC 2.0/5.1 | ✅ Direct play | |
| AC3/E-AC3 5.1 | ✅ Direct play | |
| DTS (any) | ❌ NOT supported since 2018 | Must re-encode |
| TrueHD | ❌ NOT supported | Must re-encode |
| FLAC | ❌ Video containers | Must re-encode |
| SRT (external/embedded) | ✅ Direct play | |
| PGS (embedded) | ✅ UHD Tizen 3.0+ (2017+) | |
| ASS | ⚠️ Partial (stripped flat, may glitch) | Extract to SRT |
| VobSub/DVD | ❌ Forces burn-in/transcode | |

### LG WebOS (2021+)

| Codec | Status |
|-------|--------|
| h264 8-bit | ✅ |
| HEVC Main 10 | ✅ |
| AAC/AC3/E-AC3 | ✅ |
| DTS | ❌ (dropped like Samsung) |
| SRT/PGS | ✅ |

## Key Learnings

### Video
- **HEVC Main 10 direct-plays on Samsung 2018+.** The original assumption that "Samsung doesn't support HEVC" was wrong. Re-encoding HEVC→h264 was a waste of GPU time and caused quality loss.
- **h264 10-bit (Hi10P) is dead on TVs.** No Samsung or LG model supports it. Must re-encode.
- **Resolution gates are unnecessary.** Samsung/LG play any resolution h264/HEVC up to their max (4K/8K). The old 720p/1080p/4K thresholds were redundant.
- **Entry-level Samsung panels show HDR too dark.** HDR10/PQ sources (even ones the TV technically direct-plays) look near-black in VLC and on low-nit panels. The fix is baking SDR BT.709 into the file, not adjusting TV color-tone settings at each watch. Detect HDR from `.color_transfer` (`smpte2084`=HDR10, `arib-std-b67`=HLG); `.color_primaries` (bt2020) and pix_bit_depth 10 are corroborating but not sufficient alone.
- **HDR → SDR needs `zscale` (libzimg) + `tonemap` filters.** The proven chain: `zscale=t=linear:npl=100,format=gbrpf32le,tonemap=hable:desat=0,zscale=primaries=bt709:transfer=bt709,format=yuv420p10le`. `t=linear` converts PQ/HLG to linear light, `tonemap` compresses with the hable curve, `zscale=primaries=bt709:transfer=bt709` re-tags non-HDR gamut/transfer, explicit `format=` sets the encoder pixel format. Without these filters the script refuses the file rather than emit dark HDR.

### Audio
- **AC3/E-AC3 passthrough is safe.** Both Samsung and LG hardware-decode it natively. Re-encoding AC3→AAC is unnecessary quality loss.
- **DTS is dead on modern TVs.** Samsung dropped DTS licensing in 2018. Any DTS forces transcode.
- **TrueHD is a Blu-ray codec.** No TV directly decodes it. Always re-encode.

### Subtitles
- **ASS → SRT extraction is the safest path.** Samsung Plex renders ASS flat (or glitches). SRT is universally supported.
- **ffmpeg's ASS→SRT conversion injects HTML tags** (`<b>`, `<i>`, `<font ...>`) from ASS styling. These must be stripped — Samsung Plex doesn't render HTML in SRT.
- **ASS drawing commands** (`m`, `l`, `b`, `s`, `c`, `p`) leak through ffmpeg as raw text. Must be stripped. **Coordinates are floating-point** (e.g. `6.44`, `440.59`) — the sed regex must use `[0-9]+(\.[0-9]+)?` not just `[0-9]+` or all draw lines pass through unfiltered.
- **ASS `\h` and `\N`/`\n`** become literal `\h` and `\n` in SRT output. Must be converted to spaces.
- **Image subs (PGS/DVD/DVB/XSUB) CANNOT be burned in.** libass (the `subtitles` filter) only renders text subs — a PGS burn dies at graph init with "Only text based subtitles are currently supported". The 2026-08-30 `si`-rank fix was correct but moot: image subs are now **muxed as soft tracks** and Plex burns them server-side at playback if needed. Samsung Tizen 3.0+ (2017+) direct-plays PGS anyway (see matrix below).
- **Subtitle language tags in source files can be wrong.** Trusting `.tags.language` blindly gets you German text labeled as English. The script can't detect this — it's a source file issue.

### NVENC
- **NVENC `-multipass 1` (qres) is the sweet spot.** 80-90% of `-multipass 2` (fullres) benefit at 10-20% speed cost. Fullres is 50% slower for 1-3% smaller files.
- **NVENC lava-synth test sources don't work on all drivers.** Use `nvidia-smi` for GPU detection, not a synthetic ffmpeg test encode.
- **RTX 4060 (Ada Lovelace) NVENC quality is excellent.** The old "NVENC makes files 15-30% larger" claim doesn't apply to Ada with multipass and AQ.

### Current Machine Hardware
- **GPU:** NVIDIA GeForce RTX 4060 (Ada Lovelace)
- **Driver:** 610.57.04 | **VRAM:** 8192 MiB | **ffmpeg:** n9.0.1
- **Detection result:** Full NVENC HEVC path active — `-hwaccel cuda -hwaccel_output_format cuda` + `hevc_nvenc` for no-filter re-encodes
- **Verification commands (string-match, never grep -q):**
  - `nvidia-smi --query-gpu=name --format=csv,noheader` — GPU present
  - `EL=$(ffmpeg -encoders); [[ "$EL" == *hevc_nvenc* ]]` — NVENC HEVC encoder available
  - `HL=$(ffmpeg -hwaccels); [[ "$HL" == *cuda* ]]` — CUDA hardware acceleration supported

### 2026-08-30 Changelog (v3 NVENC hardening)
- **Fixed:** encoder detection was silently BROKEN — `ffmpeg | grep -q hevc_nvenc` under `set -o pipefail` always failed (grep exits on first match → SIGPIPE → exit 141) → NVENC/libx265 always "absent" → every re-encode fell back to libx264. Detection now captures lists once and string-matches.
- **Fixed:** loop-guard `ffprobe | grep -q` had the same SIGPIPE race → same capture+string-match fix.
- **Fixed:** real-run crash on AV1/HEVC 10-bit — `-hwaccel_output_format cuda` + forced `-pix_fmt yuv420p10le` produced "Impossible to convert" (`auto_scale` can't take `cuda` frames). The pure-GPU no-filter path now feeds NVENC native CUDA frames (no `-pix_fmt`; bit depth follows source). Verified across av1 8/10-bit, h264 8/10-bit (Hi10P falls back to SW decode), hevc 8/10-bit, interlace → filter chain, and ASS two-pass sub. Filter-chain path keeps forced 10-bit (decodes to system memory).
- **Changed:** re-encodes now prefer `hevc_nvenc` (HEVC, not H.264) so burned/copy-incompatible tracks stay GPU. Software x265/x264 only as failsafes.
- **Changed:** image subs (PGS/DVD/DVB/XSUB) are now **muxed as soft tracks**, never burned. The old libass burn path could NOT render image subs — a PGS burn died at graph init ("Only text based subtitles are currently supported"). Plex handles image subs server-side at playback if the TV doesn't direct-play them (Samsung Tizen 3.0+ direct-plays PGS).
- **Added:** HDR → SDR path. HDR (`.color_transfer` = `smpte2084`/`arib-std-b67`) is never copy-eligible; such files re-encode through the tonemap filter chain (`zscale=t=linear:npl=100,format=gbrpf32le,tonemap=hable:desat=0,zscale=primaries=bt709:transfer=bt709,format=yuv420p10le`) into SDR BT.709-tagged HEVC (`-colorspace bt709 -color_trc bt709 -color_primaries bt709 -color_range tv`). Output depth stays 10-bit (banding fend-off; TV proven to play yuv420p10le). Pre-flight fails hard if `zscale`/`tonemap` are missing in the build when an HDR file is encountered (never emit dark HDR pass-through). Applies to the two 4K HDR10 Thunderbolt films (Bandit Flower / December Sky), the only HDR titles in the UC Gundam library.
- **Added:** auto-deinterlace (interlaced → yadif prepended, never copy-eligible).
- **Added:** `--dry-run` mode + post-encode ffprobe HEVC verification (delete + fail-count on mismatch).
- **Added:** two-pass subtitle cleanup reinstated (extract ASS→clean→remux as subrip via second input; temp cleaned on success/failure).
- **Verified:** FFmpeg smoke tests (NVENC 10-bit, yadif+scale+fps filter chain, subtitle burn) all exit 0. Full-library decision sim over all 227 UC Gundam files matched the real dry-run engine 189/189 with zero mismatches; only the two Thunderbolt verdicts change with the HDR path. Dry-run sampling harness (`tests/simulate_gpu.sh`) over `/mnt/dorneMedia/Pinoy` roots: 30+ files sampled across AV1/H.264/HEVC BDRip — every re-encode decision used NVENC HEVC, zero CPU, zero libx264.

### Bash
- **NEVER `cmd | grep -q` under `set -o pipefail`.** `grep -q` exits immediately on the first match and SIGPIPE-kills ffmpeg → pipeline reports exit 141 → `if` treats it as failure. This silently disabled NVENC detection for months. Capture `VAR=$(ffmpeg -encoders)` once and use `[[ "$VAR" == *pattern* ]]`.
- **`set -e pipefail` kills script on unguarded pipe failures.** Subtitle extraction `ffmpeg | sed > file` must be wrapped with `set +o pipefail` / `set -o pipefail` (read `${PIPESTATUS[0]}` immediately; note zsh calls this `$pipestatus`).
- **`(( ))` arithmetic + `set -e` trap.** `((x++))` returns 1 if expression=0, killing the script. Use `x=$((x+1))` instead.
- **Pipeline subshells lose variables.** `find | while read` runs the while loop in a subshell. Variables set inside don't survive. Use `< <(cmd)` process substitution when state needs to persist.

### jq
- **`first()` on empty input returns nothing (not `null`).** Check for both empty string AND literal `"null"` in bash.
- **`ascii_downcase` available since jq 1.5 (2015).** Universally present.
- **ISO 639-2 (`eng`/`jpn`/`kor`) is standard in ffprobe.** ISO 639-1 (`en`/`ja`/`ko`) is extremely rare but harmless to also match.

### ffprobe / ffmpeg
- **NEVER force `-pix_fmt` when decoding to CUDA frames.** `-hwaccel cuda -hwaccel_output_format cuda` + `-pix_fmt yuv420p10le` makes ffmpeg insert `auto_scale`, which cannot accept the `cuda` pixel format → `Impossible to convert between the formats supported by the filter 'Parsed_null_0' and the filter 'auto_scale_0'` on any GPU-decoded 10-bit source (AV1/HEVC). NVENC must be fed the decoder's native CUDA frames (no `-pix_fmt`; output depth follows source). Filter-chain paths decode to system memory, so they CAN keep `-pix_fmt`.
- **`pix_fmt` is more reliable than `bits_per_raw_sample` for bit depth.** `bits_per_raw_sample` is often absent. Parse bit depth from `pix_fmt` (e.g., `yuv420p10le` → 10).
- **ffprobe subtitle codec names are not what you expect.** SRT = `subrip` (not `srt`), VobSub = `dvd_subtitle`, PGS = `hdmv_pgs_subtitle`.
- **`-hwaccel cuda` + `-hwaccel_output_format cuda` keeps pipeline entirely on GPU for NVENC.** Must omit `-hwaccel_output_format cuda` when using libx264 (CPU encoder can't access GPU memory).

### Critical Plex Client Setting
- **"Maximum H.264 Level" must be set to "None" or "5.1"** in the Plex app on Samsung TVs. The default of 4.0 forces unnecessary transcodes.

## Edge Cases

- **Blu-ray REMUX with TrueHD + AC3 core**: Both appear as separate streams. AC3 copies, TrueHD re-encodes. User gets both tracks per language.
- **Mis-labeled subtitle language tags**: The script trusts the tag. German tagged as `eng` produces `.eng.srt` with German text. Not detectable.
- **Embedded cover art (mjpeg as video stream)**: `jq first()` correctly picks the real video stream. `-map 0:v:0` maps the first video stream, not the cover.
- **Font attachments**: Ignored by the script (not mapped). Harmless.
- **1280×536 ultrawide (2.39:1 720p)**: Now copied correctly (res gate removed). Previously failed the 720p height check.
- **Single TrueHD track (no AC3 core)**: Re-encodes to AAC. Correct.
- **VobSub/DVD subtitle**: Copied to MKV with [WARN] to stderr. Samsung Plex will burn it in, forcing server transcode.
