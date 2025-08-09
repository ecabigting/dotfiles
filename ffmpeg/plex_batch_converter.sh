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

echo "--- Acknowledged. Building with care and precision. Starting process in: $INPUT_ROOT_DIR ---"

# --- Main Logic: Find and process all video files ---
# Using find piped to a while-read loop is the most robust way to handle all possible filenames.
find "$INPUT_ROOT_DIR" -name "converted" -prune -o -type f -print | while IFS= read -r SOURCE_FILE; do

  # Use ffprobe to reliably identify video files, not extensions. Stderr is silenced for non-video files.
  if ! ffprobe -v error -select_streams v:0 -show_entries stream=codec_type "$SOURCE_FILE" 2>/dev/null | grep -q "codec_type=video"; then
    continue # This is not a video file, skip it silently.
  fi

  echo "------------------------------------------------------------------"
  echo ">> Processing video: $SOURCE_FILE"

  # --- Prepare all paths and names ---
  DIR_NAME=$(dirname "$SOURCE_FILE")
  BASE_NAME=$(basename "$SOURCE_FILE")
  FILE_NAME_NO_EXT="${BASE_NAME%.*}"
  OUTPUT_DIR="$DIR_NAME/converted"
  OUTPUT_FILE_MKV="$OUTPUT_DIR/${FILE_NAME_NO_EXT}.mkv"

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

  VIDEO_OPTS=""
  if [[ ("$CODEC" == "h264" || "$CODEC" == "hevc") && (($WIDTH -ge 3840 && $HEIGHT -ge 2160) || ($WIDTH -ge 1920 && $HEIGHT -ge 1080)) ]]; then
    echo "   [VIDEO]: Criteria met (Codec: $CODEC, Res: ${WIDTH}x${HEIGHT}). Copying stream."
    VIDEO_OPTS="-c:v copy"
  else
    echo "   [VIDEO]: Criteria NOT met (Codec: $CODEC, Res: ${WIDTH}x${HEIGHT}). Re-encoding to h264."
    VIDEO_OPTS="-c:v libx264 -preset slow -crf 19 -pix_fmt yuv420p"
  fi

  # --- 2. Audio Stream Logic (Corrected and Robust) ---
  AUDIO_OPTS="-c:a aac -b:a 192k"
  AUDIO_MAPS=""

  # Use 'first()' for robustness and 'ascii_downcase' for case-insensitivity. The '?' prevents errors on streams without language tags.
  JPN_AUDIO_INDEX=$(echo "$JSON_PROBE" | jq 'first(.streams[] | select(.codec_type=="audio" and ((.tags.language? | ascii_downcase) == "jpn")) | .index)')
  ENG_AUDIO_INDEX=$(echo "$JSON_PROBE" | jq 'first(.streams[] | select(.codec_type=="audio" and ((.tags.language? | ascii_downcase) == "eng")) | .index)')

  # *** LESSON LEARNED: Check for the literal string "null" which jq outputs when 'first' finds nothing. ***
  if [[ -n "$JPN_AUDIO_INDEX" && "$JPN_AUDIO_INDEX" != "null" ]]; then
    echo "   [AUDIO]: Found Japanese audio stream at index $JPN_AUDIO_INDEX."
    AUDIO_MAPS+="-map 0:$JPN_AUDIO_INDEX "
  fi
  if [[ -n "$ENG_AUDIO_INDEX" && "$ENG_AUDIO_INDEX" != "null" ]]; then
    echo "   [AUDIO]: Found English audio stream at index $ENG_AUDIO_INDEX."
    AUDIO_MAPS+="-map 0:$ENG_AUDIO_INDEX "
  fi

  # Fallback logic only runs if no specific language tracks were found.
  if [[ -z "$AUDIO_MAPS" ]]; then
    FIRST_AUDIO_INDEX=$(echo "$JSON_PROBE" | jq 'first(.streams[] | select(.codec_type=="audio") | .index)')
    if [[ -n "$FIRST_AUDIO_INDEX" && "$FIRST_AUDIO_INDEX" != "null" ]]; then
      echo "   [AUDIO]: No JPN/ENG audio found. Falling back to first audio stream at index $FIRST_AUDIO_INDEX."
      AUDIO_MAPS="-map 0:$FIRST_AUDIO_INDEX"
    else
      echo "   [AUDIO]: No audio streams found. No audio will be in the output."
      AUDIO_OPTS="" # No audio options needed if there's no audio to map.
    fi
  fi

  # --- Subtitle Logic (Final, Decoupled Design) ---
  SUBTITLE_MAPS_FOR_MKV="" # Only used for image-based subs now

  ENG_SUB_STREAMS_JSON=$(echo "$JSON_PROBE" | jq '[.streams[] | select(.codec_type=="subtitle" and ((.tags.language? | ascii_downcase) == "eng"))]')
  NUM_ENG_SUBS=$(echo "$ENG_SUB_STREAMS_JSON" | jq 'length')
  if ((NUM_ENG_SUBS > 0)); then
    echo "   [SUBTITLE]: Found $NUM_ENG_SUBS English subtitle track(s). Analyzing..."
    best_sub_index=-1
    best_score=-999
    max_line_count=-1
    echo "   [resetting criterias] -> Best Sub Index: $best_sub_index / Best score: $best_score / Max Line count: $max_line_count "
    while IFS= read -r sub_stream_json; do
      current_index=$(echo "$sub_stream_json" | jq '.index')
      current_title=$(echo "$sub_stream_json" | jq -r '.tags.title? // ""' | tr '[:upper:]' '[:lower:]')
      current_description=$(echo "$sub_stream_json" | jq -r '.tags.description? // ""' | tr '[:upper:]' '[:lower:]')
      current_score=0

      echo "    (::Current Criterias::) -> index: $current_index / title: $current_title / desc: $current_description"
      if [[ "$current_title" == *"dialog"* || "$current_title" == *"full"* ]]; then ((current_score += 10)); fi
      if [[ "$current_title" == *"sign"* || "$current_title" == *"song"* || "$current_title" == *"force"* ]]; then ((current_score -= 10)); fi
      line_count=$(ffmpeg -v error -i "$SOURCE_FILE" -map "0:$current_index" -f srt - 2>/dev/null | wc -l)
      echo "     - Candidate index $current_index: Title='${current_title}', Score=$current_score, Lines=$line_count"
      if ((current_score > best_score)); then
        best_score=$current_score
        max_line_count=$line_count
        best_sub_index=$current_index
      elif ((current_score == best_score && line_count > max_line_count)); then
        max_line_count=$line_count
        best_sub_index=$current_index
      fi
    done < <(echo "$ENG_SUB_STREAMS_JSON" | jq -c '.[]')

    if [[ "$best_sub_index" -ne -1 ]]; then
      WINNING_SUB_JSON=$(echo "$ENG_SUB_STREAMS_JSON" | jq --argjson i "$best_sub_index" '.[] | select(.index==$i)')
      SUB_CODEC=$(echo "$WINNING_SUB_JSON" | jq -r '.codec_name')
      echo "   [SUBTITLE]: Winner selected. Index: $best_sub_index (Codec: $SUB_CODEC)."

      if [[ "$SUB_CODEC" == "hdmv_pgs_subtitle" || "$SUB_CODEC" == "dvd_subtitle" ]]; then
        echo "     - Action: Copying image-based subtitle to embed in MKV."
        SUBTITLE_MAPS_FOR_MKV="-map 0:$best_sub_index -c:s copy" # Embed what we can't convert
      else
        OUTPUT_FILE_SRT="$OUTPUT_DIR/${FILE_NAME_NO_EXT}.eng.srt"
        echo "     - Action: Extracting and sanitizing text-based subtitle to $OUTPUT_FILE_SRT."
        # Step 1: Extract the raw SRT from the video file.
        # Step 2: Use sed to strip all tags, writing the clean result.
        ffmpeg -nostdin -hide_banner -v error -i "$SOURCE_FILE" -map "0:$best_sub_index" -c:s srt -f srt -y - 2>/dev/null | sed 's/<[^>]*>//g' >"$OUTPUT_FILE_SRT"
        echo "     - Sanitization complete."
      fi
    else echo "   [SUBTITLE]: Analysis failed to select a winning track."; fi
  else echo "   [SUBTITLE]: No English subtitle stream found."; fi

  # --- Assemble and Execute the MKV Conversion ---
  echo "   Building final MKV conversion command..."
  COMMAND=(ffmpeg -nostdin -hide_banner -v error -stats -i "$SOURCE_FILE" -map 0:v:0 ${VIDEO_OPTS})
  if [[ -n "$AUDIO_MAPS" ]]; then COMMAND+=($AUDIO_MAPS $AUDIO_OPTS); fi
  # Only add subtitle mapping to the MKV command if it's an image-based sub
  if [[ -n "$SUBTITLE_MAPS_FOR_MKV" ]]; then COMMAND+=($SUBTITLE_MAPS_FOR_MKV); fi
  COMMAND+=(-y "$OUTPUT_FILE_MKV")

  echo "   Executing: ${COMMAND[*]}"
  if "${COMMAND[@]}"; then echo "   SUCCESS: MKV file created successfully."; else echo "   !! FFMPEG ERROR: MKV conversion failed." >&2; fi

done

echo "--- All tasks are complete. ---"
