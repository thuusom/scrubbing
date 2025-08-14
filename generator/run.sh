#!/usr/bin/env bash
set -euo pipefail

IN=/input
OUT=/output
THUMB_EVERY_SEC="${THUMB_EVERY_SEC:-2}"
THUMB_WIDTH="${THUMB_WIDTH:-320}"

process_file() {
  src="$1"
  base="$(basename "$src")"
  name="${base%.*}"
  dest="$OUT/$name"
  mkdir -p "$dest/thumbs"

  echo "[generator] Processing: $src -> $dest"

  # 1) DASH (ISO-BMFF, fMP4)
  set -o pipefail
  ffmpeg -y -hide_banner -loglevel error -i "$src" \
    -map 0:v:0 -map 0:a\? \
    -c:v libx264 -preset veryfast -profile:v main -g 48 -keyint_min 48 -sc_threshold 0 \
    -c:a aac -b:a 128k -ac 2 \
    -seg_duration 4 -use_timeline 1 -use_template 1 \
    -init_seg_name "init-$name-\$RepresentationID\$.mp4" \
    -media_seg_name "chunk-$name-\$RepresentationID\$-\$Number%05d\$.m4s" \
    -f dash "$dest/stream.mpd" \
    || { echo "[generator] DASH encode failed for $src"; return 1; }

  [ -f "$dest/stream.mpd" ] || return 1

  # 2) Thumbnails (hver N sek., ens bredde)
  # Navngivning: thumb-000001.jpg ... + lav .vtt der peger på hvert billede.
  rm -f "$dest/thumbs/"thumb-*.jpg
  ffmpeg -y -hide_banner -loglevel error -i "$src" \
    -vf "fps=1/${THUMB_EVERY_SEC},scale=${THUMB_WIDTH}:-2" \
    -q:v 2 "$dest/thumbs/thumb-%06d.jpg"

  # 3) Lav WebVTT ud fra antal thumbs og interval
  vtt="$dest/thumbs/thumbs.vtt"
  echo "WEBVTT" > "$vtt"
  echo "" >> "$vtt"

  idx=1
  start=0
  while true; do
    file=$(printf "%s/thumbs/thumb-%06d.jpg" "$dest" "$idx")
    [[ -f "$file" ]] || break
    end=$(( start + THUMB_EVERY_SEC ))

    # format til hh:mm:ss.mmm
    fmt() { printf "%02d:%02d:%02d.000" $(( $1/3600 )) $(( ($1%3600)/60 )) $(( $1%60 )); }

    echo "$(printf "%d" "$idx")" >> "$vtt"
    echo "$(fmt $start) --> $(fmt $end)" >> "$vtt"
    echo "thumbs/thumb-$(printf "%06d" "$idx").jpg" >> "$vtt"
    echo "" >> "$vtt"

    idx=$(( idx + 1 ))
    start=$end
  done

  echo "[generator] Done: $name  (MPD + VTT)"
}

# Process eksisterende filer ved start
shopt -s nullglob
for f in "$IN"/*.mp4 "$IN"/*.mkv "$IN"/*.mov; do
  process_file "$f" || echo "[generator] Failed: $f"
done

# Overvåg mappen for nye/ændrede filer
echo "[generator] Watching $IN ..."
inotifywait -m -e close_write,create,move "$IN" | while read -r dir event file; do
  case "$file" in
    *.mp4|*.mkv|*.mov)
      process_file "$dir/$file" || echo "[generator] Failed: $dir/$file"
      ;;
    *) ;;
  esac
done