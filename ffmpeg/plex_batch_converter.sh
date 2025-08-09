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
# find "$INPUT_ROOT_DIR" -type f | while IFS= read -r SOURCE_FILE; do
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

  # --- Subtitle Logic (Modified to extract all text subs) ---
  SUBTITLE_MAPS_FOR_MKV="" # Will only be used for image-based fallbacks.

  ENG_SUB_STREAMS_JSON=$(echo "$JSON_PROBE" | jq '[.streams[] | select(.codec_type=="subtitle" and ((.tags.language? | ascii_downcase) == "eng"))]')
  NUM_ENG_SUBS=$(echo "$ENG_SUB_STREAMS_JSON" | jq 'length')
  if ((NUM_ENG_SUBS > 0)); then
    echo "   [SUBTITLE]: Found $NUM_ENG_SUBS English subtitle track(s). Processing all..."

    # Loop through every found English subtitle. No more winner selection.
    while IFS= read -r sub_stream_json; do
      current_index=$(echo "$sub_stream_json" | jq '.index')
      SUB_CODEC=$(echo "$sub_stream_json" | jq -r '.codec_name')

      # Check if it's image-based. If so, embed it and move to the next sub.
      if [[ "$SUB_CODEC" == "hdmv_pgs_subtitle" || "$SUB_CODEC" == "dvd_subtitle" ]]; then
        echo "     - Action: Found image-based sub at index $current_index. It will be embedded in the MKV."
        # We only embed the first one found to avoid clutter.
        if [[ -z "$SUBTITLE_MAPS_FOR_MKV" ]]; then
          SUBTITLE_MAPS_FOR_MKV="-map 0:$current_index -c:s copy"
        fi
        continue
      fi

      # It's a text-based sub. Extract and sanitize it.
      current_title=$(echo "$sub_stream_json" | jq -r '.tags.title? // "track'$current_index'"') # Use title, or fallback to track number
      # Sanitize the title to create a safe suffix for the filename
      sanitized_suffix=$(echo "$current_title" | tr '[:upper:]' '[:lower:]' | tr -d '()' | tr -s '[:space:]/' '_' | sed 's/__*/_/g')

      OUTPUT_FILE_SRT="$OUTPUT_DIR/${FILE_NAME_NO_EXT}.eng.${sanitized_suffix}.srt"
      echo "     - Action: Extracting and sanitizing text-based sub at index $current_index to:"
      echo "       $OUTPUT_FILE_SRT"

      ffmpeg -hide_banner -v error -i "$SOURCE_FILE" -map "0:$current_index" -c:s srt -f srt -y - 2>/dev/null | sed 's/<[^>]*>//g' >"$OUTPUT_FILE_SRT"

    done < <(echo "$ENG_SUB_STREAMS_JSON" | jq -c '.[]')
  else
    echo "   [SUBTITLE]: No English subtitle stream found."
  fi

  # --- Assemble and Execute the MKV Conversion ---
  echo "   Building final MKV conversion command..."
  COMMAND=(ffmpeg -nostdin -hide_banner -v error -stats -i "$SOURCE_FILE" -map 0:v:0 ${VIDEO_OPTS})
  if [[ -n "$AUDIO_MAPS" ]]; then COMMAND+=($AUDIO_MAPS $AUDIO_OPTS); fi
  # Only add subtitle mapping to the MKV command if an image-based sub was found
  if [[ -n "$SUBTITLE_MAPS_FOR_MKV" ]]; then COMMAND+=($SUBTITLE_MAPS_FOR_MKV); fi
  COMMAND+=(-y "$OUTPUT_FILE_MKV")

  echo "   Executing: ${COMMAND[*]}"
  if "${COMMAND[@]}"; then echo "   SUCCESS: MKV file created successfully."; else echo "   !! FFMPEG ERROR: MKV conversion failed." >&2; fi

done

echo "--- All tasks are complete. ---"
