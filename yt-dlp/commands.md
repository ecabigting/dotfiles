# link

### only 720p or lower, is a playlist, duration between 15 mins and 1hr
yt-dlp -f "best[height<=720]" --yes-playlist --match-filter "duration >= 900 & duration <= 3600" -o "/home/stifmiester/Videos/videopath/%(title)s.%(ext)s" --merge-output-format mp4 "<playlist>"
