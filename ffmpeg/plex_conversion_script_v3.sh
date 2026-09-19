#!/bin/bash
set -euo pipefail

# 2026-08-30 fix: everything lives inside main(). bash parses a function body
# as ONE compound command, so it reads the ENTIRE file front-to-back before
# running anything. Without this, bash parses trailing commands (the final
# ANY_FAIL block) lazily AFTER the big hourly while-loop finishes — if the file
# is edited/reverted in the meantime, bash reads mismatched bytes from the
# rewritten file and dies with a spurious "syntax error near unexpected token
# '('" once the loop ends. Wrapping forces a clean upfront parse.
main() {

for cmd in ffmpeg ffprobe jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "!! CRITICAL ERROR: Required command '$cmd' is not installed." >&2
    exit 1
  fi
done

# --- Encoder detection (NVENC HEVC + software x265) ---
# 2026-08-30: capture the lists once and string-match. The old
# `ffmpeg --encoders | grep -q` pattern always failed under set -o pipefail:
# grep -q exits on its first match -> ffmpeg gets SIGPIPE -> the pipeline
# reports exit 141 -> NVENC_HEVC/HAS_LIBX265 were ALWAYS 0 -> every re-encode
# silently fell back to CPU libx264 even with an RTX 4060 + hevc_nvenc present.
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

if [ "${1:-}" == "--dry-run" ]; then
  DRY_RUN=1
  shift
else
  DRY_RUN=0
fi

if [ "$#" -ne 1 ]; then
  echo "!! USAGE ERROR: You must provide exactly one argument." >&2
  echo "   Usage: $0 [--dry-run] \"/path/to/your/videos\"" >&2
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

while IFS= read -r SOURCE_FILE; do
  start_time=$(date +%s)
  start_time_human=$(date '+%Y-%m-%d %H:%M:%S')

  COPIES_VIDEO=0
  ADD_SRT_INPUT=0
  TMP_SRT_FILE=""

  # 2026-08-30: capture + string-match (the old `probe | grep -q` had the same
  # SIGPIPE/pipefail race and could silently skip files).
  VCODEC_TYPE=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_type "$SOURCE_FILE" 2>/dev/null || true)
  if [[ "$VCODEC_TYPE" != *codec_type=video* ]]; then
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

  if (( ! DRY_RUN )); then
    mkdir -p "$OUTPUT_DIR"
  fi

  JSON_PROBE=$(ffprobe -v quiet -print_format json -show_format -show_streams "$SOURCE_FILE")
  echo "   Target for conversion: $OUTPUT_FILE_MKV"

  # ---- 2. English subtitle decision (English-only; one largest track) ----
  # largest English sub by size (NUMBER_OF_BYTES -> BPS*DURATION -> DURATION alone -> bit_rate*duration -> 0):
  #   text-based  -> muxed embedded as subrip (copy if already subrip, else convert)
  #   image-based -> BURNED into the video (GPU filter-chain re-encode)
  SUB_MAP_OPTS=""
  BURN_FILTER=""
  ENGLISH_SUB_JSON=$(echo "$JSON_PROBE" | jq -c '
    ([.streams[] | select(.codec_type=="subtitle" and ((.tags.language? // "" | ascii_downcase) as $l | $l == "eng" or $l == "en"))]
     | map(. as $s | {
         st: $s,
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
        # 2026-08-30 fix: the subtitles filter's `si` is the 0-based RANK among
        # subtitle streams, NOT the global stream index. A PGS at global index 5
        # with multiple audio/sub tracks previously produced an uninitialized
        # filter graph ("Unable to locate subtitle stream") -> burn re-encode died.
        SUB_SI=$(echo "$JSON_PROBE" | jq -r --argjson tidx "$SUB_IDX" \
          '[.streams[] | select(.codec_type=="subtitle") | .index] | index($tidx)')
        [ "$SUB_SI" == "null" ] && SUB_SI=0
        ESC_FILE=$(printf '%s' "$SOURCE_FILE" | sed 's/\\/\\\\/g; s/:/\\:/g; s/,/\\,/g; s/;/\\;/g; s/'"'"'/\\'"'"'/g; s/\[/\\[/g; s/\]/\\]/g; s/ /\\ /g')
        BURN_FILTER="subtitles='${ESC_FILE}':si=${SUB_SI}"
        ;;
      *)
        echo "   [SUBTITLE]: Largest English sub is text-based ($SUB_CODEC at stream $SUB_IDX). Muxing as subrip."
        if [ "$SUB_CODEC" == "subrip" ]; then
          SUB_MAP_OPTS="-map 0:${SUB_IDX} -c:s copy -metadata:s:s:0 language=eng"
        else
          # 2026-08-30: two-pass cleanup (v2 lesson). Pass 1 extracts the text
          # sub and strips ASS/HTML/drawing junk; pass 2 remuxes the clean SRT
          # as subrip via a second input. Temp SRT is removed on success AND
          # failure; if extraction fails, subtitles are dropped (video proceeds).
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
    esac
  else
    echo "   [SUBTITLE]: No English subtitle found. No subtitle tracks included, no burn."
  fi

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

  # NOTE: BURN_FILTER is set by the subtitle section (#2 above) BEFORE this block.

  # ---- 3. Video decision ----
  # Proven copy ceiling: h264/yuv420p OR hevc/yuv420p|yuv420p10le, <=1920x1088,
  # <=30fps, no burn, AND progressive. Anything else -> re-encode.
  # 2026-08-30: re-encodes ALWAYS prefer hevc_nvenc (GPU). With a filter chain
  # (deinterlace/resize/fps/burn) NVENC runs WITHOUT -hwaccel cuda: filters run
  # on CPU frames, the encode still happens on the GPU. CPU libx265 is a failsafe.
  VIDEO_FILTERS=""
  VIDEO_OPTS=()
  HWACCEL=""
  # 2026-08-30 fix: NVENC_OPTS no longer forces -pix_fmt. When frames are
  # delivered as CUDA hw frames (via -hwaccel_output_format cuda) a forced
  # -pix_fmt yuv420p10le inserts auto_scale, which cannot accept the `cuda`
  # pix fmt -> "Impossible to convert between the formats supported by the
  # filter 'Parsed_null_0' and the filter 'auto_scale_0'" on any GPU-decoded
  # 10-bit source (AV1/HEVC). The pure-GPU path now feeds NVENC the decoder's
  # native frames (output bit depth follows the source). The filter-chain path
  # re-adds -pix_fmt because it decodes to system memory (see below).
  NVENC_OPTS=(-c:v hevc_nvenc -preset p7 -tune hq -cq 27 -rc vbr -multipass 1 -b_ref_mode middle -bf 4 -spatial-aq 1 -temporal-aq 1 -rc-lookahead 32)
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
        VIDEO_OPTS=("${NVENC_OPTS[@]}" -pix_fmt yuv420p10le -vf "$VIDEO_FILTERS")
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

  # ---- 5. Assemble, execute & verify ----
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

  echo "   Executing: ${COMMAND[*]}"
  if (( DRY_RUN )); then
    echo "   [DRY-RUN]: command shown only; execution skipped."
  else
    if "${COMMAND[@]}"; then
      echo "   SUCCESS: MKV file created successfully."
      # ---- Verify (GPU + verify + warn) ----
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
    # temp SRT cleanup on both success and failure
    if [ -n "$TMP_SRT_FILE" ]; then
      rm -f "$TMP_SRT_FILE"
    fi
  fi

  end_time=$(date +%s)
  end_time_human=$(date '+%Y-%m-%d %H:%M:%S')
  elapsed=$((end_time - start_time))
  echo "Started:  $start_time_human"
  echo "Finished: $end_time_human"
  echo "Elapsed time for $FILE_NAME_NO_EXT: ${elapsed} seconds"
done < <(find "$INPUT_ROOT_DIR" -name "converted" -prune -o \( -type f -o -type l \) -printf '%f\t%p\n' | sort -k1 | cut -f2)

if (( ANY_FAIL > 0 )); then
  echo "--- Process completed with ${ANY_FAIL} file(s) in error. ---"
  exit 1
fi
echo "--- All tasks are complete. ---"

}

main "$@"