#!/bin/bash

# --- HOW TO USE ---
#
# This script processes video files for optimal Plex Direct Play.
# It places all converted videos and subtitles into a "converted" subfolder.
#
# 1. With a path argument to process a specific folder:
#    prepare_for_plex.sh "/path/to/my/video folder/"
#
# 2. Without an argument to process the current folder:
#    prepare_for_plex.sh
#
# ------------------

# --- Configuration ---
MAX_HEIGHT=1080
VIDEO_CODEC_TARGET=libx264
VIDEO_CRF=18
AUDIO_CODEC_TARGET=aac
AUDIO_CHANNELS=2
AUDIO_BITRATE=192k

# --- Step 1: Handle Input Path ---
if [ -z "$1" ]; then
  TARGET_DIR="."
  echo "No folder path provided. Using the current directory."
else
  TARGET_DIR="$1"
  echo "Target folder set to: $TARGET_DIR"
fi

# Validate that the target directory actually exists
if [ ! -d "$TARGET_DIR" ]; then
  echo "Error: Directory '$TARGET_DIR' not found."
  exit 1
fi

# --- Step 2: Define and Create the Output Directory ---
CONVERTED_DIR="$TARGET_DIR/converted"
echo "Output will be saved to: $CONVERTED_DIR"
mkdir -p "$CONVERTED_DIR" # The -p flag creates the directory if it doesn't exist, and does nothing if it does.

# --- Step 3: Main Processing Loop ---
for f in "$TARGET_DIR"/*.mkv; do
  [ -e "$f" ] || continue # Prevents errors if no .mkv files are found

  # Get just the filename part from the full path
  base_filename=$(basename "$f")

  # Define the final output paths inside the "converted" directory
  output_mkv="$CONVERTED_DIR/${base_filename%.*}_plex.mkv"
  output_srt="$CONVERTED_DIR/${base_filename%.*}.eng.srt"

  # Check if the output file already exists in the converted folder to avoid re-doing work
  if [ -f "$output_mkv" ]; then
    echo "Skipping '$base_filename' because it has already been converted."
    continue
  fi

  echo "----------------------------------------------------"
  echo "Processing file: $base_filename"

  # Probe the file to get stream information
  probe_data=$(ffprobe -v quiet -print_format json -show_streams "$f")

  # --- Video Logic ---
  video_stream_data=$(echo "$probe_data" | jq '.streams[] | select(.codec_type=="video")' | jq -s '.[0]')
  video_codec=$(echo "$video_stream_data" | jq -r '.codec_name')
  video_height=$(echo "$video_stream_data" | jq -r '.height')

  if [[ "$video_codec" == "h264" || "$video_codec" == "hevc" ]] && [[ "$video_height" -le "$MAX_HEIGHT" ]]; then
    echo "Video is compatible (Codec: $video_codec, Height: $video_height). Setting to copy."
    video_opts="-c:v copy"
  else
    echo "Video needs conversion (Codec: $video_codec, Height: $video_height). Re-encoding..."
    video_opts="-c:v $VIDEO_CODEC_TARGET -crf $VIDEO_CRF -vf 'scale=w=-2:h=min(ih,$MAX_HEIGHT)' -preset medium"
  fi

  # --- Audio Logic ---
  audio_stream_data=$(echo "$probe_data" | jq '.streams[] | select(.codec_type=="audio")' | jq -s '.[0]')
  audio_codec=$(echo "$audio_stream_data" | jq -r '.codec_name')
  audio_channels=$(echo "$audio_stream_data" | jq -r '.channels')

  if [[ "$audio_codec" == "$AUDIO_CODEC_TARGET" ]] && [[ "$audio_channels" -le "$AUDIO_CHANNELS" ]]; then
    echo "Audio is compatible (Codec: $audio_codec, Channels: $audio_channels). Setting to copy."
    audio_opts="-c:a copy"
  else
    echo "Audio needs conversion (Codec: $audio_codec, Channels: $audio_channels). Re-encoding..."
    audio_opts="-c:a $AUDIO_CODEC_TARGET -ac $AUDIO_CHANNELS -b:a $AUDIO_BITRATE"
  fi

  # --- Refined Subtitle Logic ---
  subtitle_stream_index=""
  subtitle_stream_index=$(echo "$probe_data" | jq -r '.streams[] | select(.codec_type=="subtitle" and .tags.language=="eng") | .index' | head -n 1)

  if [ -z "$subtitle_stream_index" ]; then
    subtitle_stream_index=$(echo "$probe_data" | jq -r '.streams[] | select(.codec_type=="subtitle") | .index' | head -n 1)
  fi

  if [ -n "$subtitle_stream_index" ]; then
    echo "Found subtitle to extract at stream index: $subtitle_stream_index."
    ffmpeg -hide_banner -loglevel error -i "$f" -map 0:$subtitle_stream_index -y "$output_srt" && sed -i'' 's/<[^>]*>//g' "$output_srt"
    if [ $? -ne 0 ]; then
      echo "Warning: Failed to extract subtitle from stream $subtitle_stream_index for '$base_filename'."
    fi
  else
    echo "No subtitle streams found in '$base_filename'."
  fi

  # --- Final Conversion Command ---
  echo "Building new Plex-optimized MKV file..."
  ffmpeg -hide_banner -loglevel error -i "$f" \
    -map 0:v:0 ${video_opts} \
    -map 0:a:0 ${audio_opts} \
    -y "$output_mkv"

  echo "Finished creating $output_mkv"
done

echo "----------------------------------------------------"
echo "All tasks complete."
