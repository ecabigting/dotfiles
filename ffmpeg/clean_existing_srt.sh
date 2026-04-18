#!/bin/bash
# Clean existing .srt files by removing curly brace patterns and SVG path data
# Usage: ./clean_existing_srt.sh /path/to/srt/directory

SRT_DIR="$1"

if [ -z "$SRT_DIR" ]; then
  echo "Usage: $0 /path/to/srt/directory"
  exit 1
fi

if [ ! -d "$SRT_DIR" ]; then
  echo "Error: Directory '$SRT_DIR' not found"
  exit 1
fi

echo "Processing .srt files in: $SRT_DIR"
FILES_PROCESSED=0

# Find all .srt files and clean them
while IFS= read -r -d '' file; do
  if [ -f "$file" ]; then
    echo "Processing: $file"
    # Create backup and clean in one pass
    sed -i.bak -e 's/{[^}]*}//g' -e '/^[[:space:]]*[ml][[:space:]]*[0-9][0-9 ]*$/d' "$file"
    ((FILES_PROCESSED++))
  fi
done < <(find "$SRT_DIR" -name "*.srt" -type f -print0)

echo "Done! Processed $FILES_PROCESSED .srt files"
echo "Original files backed up with .bak extension"
