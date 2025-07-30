## extract subtitle ass to .srt file
```bash
for f in *.mkv; do srt_file="${f%.*}.srt"; ffmpeg -i "$f" -map 0:4 -y "$srt_file" && sed -i'' 's/<[^>]*>//g' "$srt_file"; done
```
This script extracts subtitle from `.mkv` files and put time into `.srt` files. Then reads the same srt file with sed and remove any html tags.

Note the following part of the script:
- `-map 0:4` is the stream in the file that points the subtitle we want to extract. You must run `ffmpeg -i <video_file>.mkv` to find the correct stream

## for subrip subs
```bash
for f in *.mkv; do ffmpeg -i "$f" -map 0:5 -c:s copy "${f%.*}.srt"; done
```
Note the following part of the script:
- `-c:s copy` this is copying the instead of trying to convert it. Since subrip has no formatting like ass subs, this is easier
