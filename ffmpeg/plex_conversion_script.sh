#!/bin/bash

# --- Safety First: Exit on error, and treat unset variables as an error ---
# 'e' exits on error, 'u' treats unset variables as an error, 'pipefail' makes pipes fail if any component fails.
set -euo pipefail

# --- Prerequisite Check: Ensure required tools are installed ---
# This prevents cryptic errors later by checking for dependencies first.
for cmd in ffmpeg ffprobe jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "!! CRITICAL ERROR: Required command '$cmd' is not installed." >&2
    echo "!! Please install it to proceed. On Debian/Ubuntu: sudo apt install ffmpeg jq" >&2
    exit 1
  fi
done

# --- Hardware Acceleration & Encoder Detection ---
HWACCEL=""
USE_NVENC=0
if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q h264_nvenc && nvidia-smi &>/dev/null; then
  HWACCEL="-hwaccel cuda -hwaccel_output_format cuda"
  USE_NVENC=1
  echo "--- NVIDIA NVENC GPU encoding enabled ---"
elif ffmpeg -hide_banner -hwaccels 2>/dev/null | grep -q cuda; then
  HWACCEL="-hwaccel cuda"
  echo "--- NVIDIA CUDA decode enabled (CPU encode fallback) ---"
fi

# --- Input Validation: Check for exactly one directory argument ---
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

# --- Main Logic: Find and process all video files ---
# Using find piped to a while-read loop is the most robust way to handle all possible filenames.
# find "$INPUT_ROOT_DIR" -type f | while IFS= read -r SOURCE_FILE; do
find "$INPUT_ROOT_DIR" -name "converted" -prune -o -type f -printf '%f\t%p\n' | sort -k1 | cut -f2 | while IFS= read -r SOURCE_FILE; do
  start_time=$(date +%s)
  start_time_human=$(date '+%Y-%m-%d %H:%M:%S')
  # Use ffprobe to reliably identify video files, not extensions. Stderr is silenced for non-video files.
  if ! ffprobe -v error -select_streams v:0 -show_entries stream=codec_type "$SOURCE_FILE" 2>/dev/null | grep -q "codec_type=video"; then
    continue # This is not a video file, skip it silently.
  fi

  # --- Prepare all paths and names ---
  DIR_NAME=$(dirname "$SOURCE_FILE")
  BASE_NAME=$(basename "$SOURCE_FILE")
  FILE_NAME_NO_EXT="${BASE_NAME%.*}"
  OUTPUT_DIR="$DIR_NAME/converted"
  OUTPUT_FILE_MKV="$OUTPUT_DIR/${FILE_NAME_NO_EXT}.mkv"

  echo "==============================================================="
  echo ">> Processing video: [ $FILE_NAME_NO_EXT ]"

  if [ -f "$OUTPUT_FILE_MKV" ]; then
    echo "   [SKIP]: Output file already exists."
    continue
  fi

  echo "   Target for conversion: $OUTPUT_FILE_MKV"
  mkdir -p "$OUTPUT_DIR"
  # --- Analyze Source File: Run ffprobe ONCE and store the data ---
  # This is efficient and provides all the data we need in a structured format.
  JSON_PROBE=$(ffprobe -v quiet -print_format json -show_format -show_streams "$SOURCE_FILE")

  # --- 1. Video Stream Logic (Corrected and Robust) ---
  # *** LESSON LEARNED: Use jq's internal 'first()' function, not an external pipe to 'head'. ***
  VIDEO_STREAM_JSON=$(echo "$JSON_PROBE" | jq 'first(.streams[] | select(.codec_type=="video"))')

  # Defensive check: ensure a video stream was actually found.
  if [[ -z "$VIDEO_STREAM_JSON" || "$VIDEO_STREAM_JSON" == "null" ]]; then
    echo "   !! ERROR: Could not find a video stream in this file. Skipping."
    continue
  fi

  CODEC=$(echo "$VIDEO_STREAM_JSON" | jq -r '.codec_name')
  WIDTH=$(echo "$VIDEO_STREAM_JSON" | jq -r '.width')
  HEIGHT=$(echo "$VIDEO_STREAM_JSON" | jq -r '.height')
  PIX_FMT=$(echo "$VIDEO_STREAM_JSON" | jq -r '.pix_fmt // "yuv420p"')
  BITDEPTH=$(echo "$PIX_FMT" | grep -oP '\d+(?=le|be)' || echo "8")

  VIDEO_OPTS=""
  if [[ ("$CODEC" == "h264" && BITDEPTH -lt 10) || ("$CODEC" == "hevc" && BITDEPTH -le 10) ]]; then
    echo "   [VIDEO]: Compatible codec (Codec: $CODEC, Res: ${WIDTH}x${HEIGHT}, BitDepth:${BITDEPTH}). Copying stream."
    VIDEO_OPTS="-c:v copy"
  else
    if ((USE_NVENC)); then
      echo "   [VIDEO]: Needs re-encode. Re-encoding to h264 via NVENC."
      VIDEO_OPTS="-c:v h264_nvenc -preset p7 -tune hq -cq 19 -rc vbr -multipass 1 -b_ref_mode middle -bf 4 -spatial-aq 1 -temporal-aq 1 -rc-lookahead 32 -pix_fmt yuv420p"
    else
      echo "   [VIDEO]: Needs re-encode. Re-encoding to h264 via CPU."
      VIDEO_OPTS="-c:v libx264 -preset medium -crf 19 -pix_fmt yuv420p"
    fi
  fi

  # --- 2. Audio Stream Logic ---
  # Collect all JPN/ENG/KOR audio streams in priority order: KOR, then JPN, then ENG.
  AUDIO_MAPS=""
  AUDIO_CODEC_OPTS=""
  AUDIO_METADATA_OPTS=""
  audio_stream_counter=0

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

  if [[ -n "$AUDIO_STREAMS_JSON" && "$AUDIO_STREAMS_JSON" != "null" ]]; then
    while IFS= read -r audio_stream_json; do
      lang=$(echo "$audio_stream_json" | jq -r '(.tags.language? // "" | ascii_downcase)')
      idx=$(echo "$audio_stream_json" | jq -r '.index')
      ch=$(echo "$audio_stream_json" | jq -r '.channels // 2')
      acodec=$(echo "$audio_stream_json" | jq -r '.codec_name')

      case "$lang" in
        kor|ko) lang_name="Korean" ;;
        jpn|ja) lang_name="Japanese" ;;
        eng|en) lang_name="English" ;;
      esac

      echo "   [AUDIO]: Found ${lang_name} audio at index $idx ($ch channels)."
      AUDIO_MAPS+="-map 0:$idx "

      if [[ "$acodec" == "aac" || "$acodec" == "ac3" || "$acodec" == "eac3" ]]; then
        echo "     - Action: Copying existing ${acodec^^} stream."
        AUDIO_CODEC_OPTS+="-c:a:$audio_stream_counter copy "
      elif ((ch >= 6)); then
        echo "     - Action: Setting ${lang_name} track to 5.1 AAC (384k)."
        AUDIO_CODEC_OPTS+="-c:a:$audio_stream_counter aac -b:a:$audio_stream_counter 384k -ac:a:$audio_stream_counter 6 "
      else
        echo "     - Action: Setting ${lang_name} track to Stereo AAC (192k)."
        AUDIO_CODEC_OPTS+="-c:a:$audio_stream_counter aac -b:a:$audio_stream_counter 192k -ac:a:$audio_stream_counter 2 "
      fi

      AUDIO_METADATA_OPTS+="-metadata:s:a:$audio_stream_counter title=\"${lang_name}\" "
      audio_stream_counter=$((audio_stream_counter + 1))
    done < <(echo "$AUDIO_STREAMS_JSON")
  fi

  # Fallback: no JPN/ENG/KOR audio found, grab first available audio stream
  if [[ -z "$AUDIO_MAPS" ]]; then
    FIRST_AUDIO_INDEX=$(echo "$JSON_PROBE" | jq 'first(.streams[] | select(.codec_type=="audio") | .index)')
    if [[ -n "$FIRST_AUDIO_INDEX" && "$FIRST_AUDIO_INDEX" != "null" ]]; then
      echo "   [AUDIO]: No JPN/ENG/KOR audio found. Falling back to first audio stream at index $FIRST_AUDIO_INDEX."
      AUDIO_MAPS="-map 0:$FIRST_AUDIO_INDEX"
      AUDIO_CODEC_OPTS="-c:a aac -b:a 192k -ac 2"
      AUDIO_METADATA_OPTS="-metadata:s:a:0 title=\"Audio\" "
    else
      echo "   [AUDIO]: No audio streams found. No audio will be in the output."
    fi
  fi

  # --- Subtitle Logic ---
  # Text-based EN/JP subs: extracted to Plex-compatible external SRT files.
  # Image-based subs (PGS/DVD/VobSub/DVB): copied into the output MKV.
  SUBTITLE_MAPS_FOR_MKV=""
  image_sub_counter=0

  TEXT_SUB_STREAMS_JSON=$(echo "$JSON_PROBE" | jq -c '
    [.streams[] | select(.codec_type=="subtitle" and ((.tags.language? // "" | ascii_downcase) as $l | $l == "eng" or $l == "en" or $l == "jpn" or $l == "ja"))]
    | sort_by(
        if (.tags.language? // "" | ascii_downcase) == "jpn" or (.tags.language? // "" | ascii_downcase) == "ja" then 0
        else 1 end
      , .index)
    | .[]
  ')
  NUM_TEXT_SUBS=$(echo "$JSON_PROBE" | jq '[.streams[] | select(.codec_type=="subtitle" and ((.tags.language? // "" | ascii_downcase) as $l | $l == "eng" or $l == "en" or $l == "jpn" or $l == "ja"))] | length')

  eng_sub_num=0
  jpn_sub_num=0

  if ((NUM_TEXT_SUBS > 0)); then
    echo "   [SUBTITLE]: Found $NUM_TEXT_SUBS EN/JP subtitle track(s). Processing..."

    while IFS= read -r sub_stream_json; do
      current_index=$(echo "$sub_stream_json" | jq '.index')
      SUB_CODEC=$(echo "$sub_stream_json" | jq -r '.codec_name')
      sub_lang_tag=$(echo "$sub_stream_json" | jq -r '(.tags.language? // "" | ascii_downcase)')

      echo "   Subtitle Codec Found: $SUB_CODEC on index $current_index (language: $sub_lang_tag)"

      if [[ "$SUB_CODEC" == "hdmv_pgs_subtitle" || "$SUB_CODEC" == "dvb_subtitle" ]]; then
        echo "     - Action: Copying image-based sub at index $current_index into MKV."
        SUBTITLE_MAPS_FOR_MKV+="-map 0:$current_index -c:s:$image_sub_counter copy "
        image_sub_counter=$((image_sub_counter + 1))
      elif [[ "$SUB_CODEC" == "dvd_subtitle" || "$SUB_CODEC" == "xsub" ]]; then
        echo "     - Action: Copying image-based sub at index $current_index into MKV."
        echo "       [WARN] VobSub/XSUB subtitle may force server transcode on Samsung/LG TV." >&2
        SUBTITLE_MAPS_FOR_MKV+="-map 0:$current_index -c:s:$image_sub_counter copy "
        image_sub_counter=$((image_sub_counter + 1))
      else
        case "$sub_lang_tag" in
          jpn|ja) lang_suffix="jpn"; jpn_sub_num=$((jpn_sub_num + 1)); sub_num=$jpn_sub_num ;;
          *)      lang_suffix="eng"; eng_sub_num=$((eng_sub_num + 1)); sub_num=$eng_sub_num ;;
        esac

        if ((sub_num == 1)); then
          OUTPUT_FILE_SRT="$OUTPUT_DIR/${FILE_NAME_NO_EXT}.${lang_suffix}.srt"
        else
          OUTPUT_FILE_SRT="$OUTPUT_DIR/${FILE_NAME_NO_EXT}.${lang_suffix}.${sub_num}.srt"
        fi

        echo "     - Action: Extracting text-based sub at index $current_index to:"
        echo "       $OUTPUT_FILE_SRT"

        set +o pipefail
        ffmpeg -nostdin -hide_banner -v error -i "$SOURCE_FILE" -map "0:$current_index" -f srt -y - 2>/tmp/srt_ffmpeg_error.log \
          | sed -E '
              s/\{[^}]*\}//g
              s/<[^>]*>//g
              s/\\h/ /g
              s/\\[nN]/ /g
               /^[[:space:]]*[mnlbscp][[:space:]]+-?[0-9]+(\.[0-9]+)?[[:space:]]+-?[0-9]+(\.[0-9]+)?/d
            ' >"$OUTPUT_FILE_SRT"
        srt_exit=${PIPESTATUS[0]}
        set -o pipefail

        if ((srt_exit != 0)); then
          echo "       [WARN] SRT extraction failed at index $current_index (ffmpeg exit $srt_exit)." >&2
          echo "       Reason: $(head -1 /tmp/srt_ffmpeg_error.log)" >&2
          rm -f "$OUTPUT_FILE_SRT"
        else
          echo "       [OK] SRT extracted."
        fi
      fi
    done < <(echo "$TEXT_SUB_STREAMS_JSON")
  else
    echo "   [SUBTITLE]: No EN/JP subtitle stream found."
  fi

  # --- Assemble and Execute the MKV Conversion ---
  echo "   Building final MKV conversion command..."
  COMMAND=(ffmpeg -nostdin -hide_banner -v error -stats $HWACCEL -i "$SOURCE_FILE" -map 0:v:0 ${VIDEO_OPTS})

  if [[ -n "$AUDIO_MAPS" ]]; then COMMAND+=($AUDIO_MAPS $AUDIO_CODEC_OPTS $AUDIO_METADATA_OPTS); fi
  if [[ -n "$SUBTITLE_MAPS_FOR_MKV" ]]; then COMMAND+=($SUBTITLE_MAPS_FOR_MKV); fi
  COMMAND+=(-y "$OUTPUT_FILE_MKV")

  echo "   Executing: ${COMMAND[*]}"
  if "${COMMAND[@]}"; then echo "   SUCCESS: MKV file created successfully."; else echo "   !! FFMPEG ERROR: MKV conversion failed." >&2; fi

  end_time=$(date +%s)
  end_time_human=$(date '+%Y-%m-%d %H:%M:%S')
  elapsed=$((end_time - start_time))
  echo "Started: $start_time_human"
  echo "Finished: $end_time_human"
  echo "Elapsed time for $FILE_NAME_NO_EXT: ${elapsed} seconds"
done

echo "--- All tasks are complete. ---"
