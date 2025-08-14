#!/usr/bin/env bash
set -euo pipefail

IN=/input
OUT=/output
THUMB_EVERY_SEC="${THUMB_EVERY_SEC:-2}"
THUMB_WIDTH="${THUMB_WIDTH:-320}"

# printf hh:mm:ss.mmm from seconds (integer)
fmt_hhmmss () {
  local s=$1
  printf "%02d:%02d:%02d.000" $(( s/3600 )) $(( (s%3600)/60 )) $(( s%60 ))
}

inject_dash_image_set () {
  local mpd="$1"          # $dest/stream.mpd
  local rel_path="$2"     # thumbs/thumb-$Number$.jpg (relative to MPD)
  local width="$3"
  local height="$4"
  local dur="$5"          # THUMB_EVERY_SEC (seconds, integer)

  # Build the Image AdaptationSet XML
  local tmp_as
  tmp_as="$(mktemp)"
  cat >"$tmp_as" <<EOF
  <AdaptationSet id="201" contentType="image" mimeType="image/jpeg" segmentAlignment="true">
    <Role schemeIdUri="urn:mpeg:dash:role:2011" value="trickmode"/>
    <Representation id="img-1" bandwidth="5000" width="$width" height="$height" codecs="jpeg">
      <EssentialProperty schemeIdUri="http://dashif.org/guidelines/trickmode" value="1"/>
      <SegmentTemplate timescale="1" duration="$dur" startNumber="1" media="$rel_path"/>
    </Representation>
  </AdaptationSet>
EOF

  # Backup
  local bak="${mpd}.bak"
  cp "$mpd" "$bak"

  # Insert block before first </Period>
  local tmp_out
  tmp_out="$(mktemp)"
  awk -v add="$(<"$tmp_as")" '
    BEGIN{ inserted=0 }
    {
      line=$0
      if (!inserted && line ~ /<\/Period>/) {
        sub(/<\/Period>/, add "\n</Period>", line)
        inserted=1
      }
      print line
    }
  ' "$bak" > "$tmp_out"

  mv "$tmp_out" "$mpd"
  rm -f "$tmp_as"
}

write_hls_image_playlists () {
  local dest="$1"         # $dest directory
  local count="$2"        # number of thumbs
  local width="$3"
  local height="$4"
  local td="$5"           # target duration (THUMB_EVERY_SEC)

  local img_pl="$dest/thumbs/thumbs.m3u8"
  local master_img="$dest/thumbs/thumbs_master.m3u8"

  # Image media playlist
  {
    echo "#EXTM3U"
    echo "#EXT-X-VERSION:7"
    echo "#EXT-X-TARGETDURATION:${td}"
    echo "#EXT-X-PLAYLIST-TYPE:VOD"
    echo "#EXT-X-IMAGES-ONLY"
    echo "#EXT-X-MEDIA-SEQUENCE:1"
    for ((i=1; i<=count; i++)); do
      echo "#EXTINF:${td}.0,"
      echo "thumb-${i}.jpg"
    done
    echo "#EXT-X-ENDLIST"
  } > "$img_pl"

  # Minimal image-only master (handy for testing)
  {
    echo "#EXTM3U"
    echo "#EXT-X-VERSION:7"
    echo "#EXT-X-IMAGE-STREAM-INF:BANDWIDTH=25000,RESOLUTION=${width}x${height},CODECS=\"jpeg\",URI=\"thumbs.m3u8\""
  } > "$master_img"
}

# Build a simple HLS VIDEO VOD (single variant, AVC+AAC, TS segments)
write_hls_video () {
  local src="$1"      # input file
  local dest="$2"     # /output/<name>
  local v_width="$3"  # video width (from ffprobe)
  local v_height="$4" # video height (from ffprobe)

  mkdir -p "$dest/hls"

  ffmpeg -y -hide_banner -loglevel error -i "$src" \
    -map 0:v:0 -map 0:a\? \
    -c:v libx264 -preset veryfast -profile:v main \
    -g 48 -keyint_min 48 -sc_threshold 0 \
    -c:a aac -b:a 128k -ac 2 \
    -f hls \
    -hls_time 4 -hls_playlist_type vod \
    -hls_segment_filename "$dest/hls/chunk-%05d.ts" \
    "$dest/hls/stream.m3u8"

  # Estimate BANDWIDTH (rough): 2 Mbps video + 128 kbps audio
  local bw="2128000"
  local codecs="avc1.4d401f,mp4a.40.2"
  # If there was no audio, simplify codecs (optional; we keep both for simplicity)

  # HLS video master with image track reference
  # Note: the relative URI to the image playlist is ../thumbs/thumbs.m3u8
  {
    echo "#EXTM3U"
    echo "#EXT-X-VERSION:7"
    echo "#EXT-X-INDEPENDENT-SEGMENTS"
    echo "#EXT-X-STREAM-INF:BANDWIDTH=${bw},RESOLUTION=${v_width}x${v_height},CODECS=\"${codecs}\""
    echo "stream.m3u8"
    echo "#EXT-X-IMAGE-STREAM-INF:BANDWIDTH=25000,RESOLUTION=${v_width}x${v_height},CODECS=\"jpeg\",URI=\"../thumbs/thumbs.m3u8\""
  } > "$dest/hls/master.m3u8"
}

process_file() {
  local src="$1"
  local base
  base="$(basename "$src")"
  local name="${base%.*}"
  local dest="$OUT/$name"
  mkdir -p "$dest/thumbs"

  echo "[generator] Processing: $src -> $dest"

  # -----------------------------
  # 0) Probe source dimensions (for HLS master + image playlists)
  # -----------------------------
  local vdim
  vdim=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$src" || echo "0,0")
  local v_width v_height
  v_width=$(echo "$vdim" | cut -d, -f1)
  v_height=$(echo "$vdim" | cut -d, -f2)

  # -----------------------------
  # 1) DASH (video+audio)
  # -----------------------------
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

  # -----------------------------
  # 2) Thumbnails (JPEG) — unpadded numbering to match MPD $Number$
  # -----------------------------
  rm -f "$dest/thumbs/"thumb-*.jpg
  ffmpeg -y -hide_banner -loglevel error -i "$src" \
    -vf "fps=1/${THUMB_EVERY_SEC},scale=${THUMB_WIDTH}:-2" \
    -q:v 2 "$dest/thumbs/thumb-%d.jpg"

  # Count thumbs
  local count
  count=$(ls -1 "$dest/thumbs"/thumb-*.jpg 2>/dev/null | wc -l | awk '{print $1}')
  if [[ "$count" -eq 0 ]]; then
    echo "[generator] No thumbnails created"; return 1
  fi

  # Dimensions from first thumb
  local first="$dest/thumbs/thumb-1.jpg"
  local dim
  dim=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$first" || echo "0,0")
  local t_width t_height
  t_width=$(echo "$dim" | cut -d, -f1)
  t_height=$(echo "$dim" | cut -d, -f2)

  # -----------------------------
  # 3) WebVTT (fallback)
  # -----------------------------
  local vtt="$dest/thumbs/thumbs.vtt"
  {
    echo "WEBVTT"
    echo ""
    local idx=1
    local start=0
    while [[ $idx -le $count ]]; do
      local end=$(( start + THUMB_EVERY_SEC ))
      echo "$idx"
      echo "$(fmt_hhmmss $start) --> $(fmt_hhmmss $end)"
      echo "thumbs/thumb-${idx}.jpg"
      echo ""
      idx=$(( idx + 1 ))
      start=$end
    done
  } > "$vtt"

  # -----------------------------
  # 4) DASH Image AdaptationSet (standard)
  # -----------------------------
  inject_dash_image_set \
    "$dest/stream.mpd" \
    "thumbs/thumb-\$Number\$.jpg" \
    "$t_width" \
    "$t_height" \
    "$THUMB_EVERY_SEC"

  # -----------------------------
  # 5) HLS Image Media Playlist (standard)
  # -----------------------------
  write_hls_image_playlists "$dest" "$count" "$t_width" "$t_height" "$THUMB_EVERY_SEC"

  # -----------------------------
  # 6) HLS VIDEO stream (+ master that references image playlist)
  # -----------------------------
  write_hls_video "$src" "$dest" "$v_width" "$v_height"

  echo "[generator] Done: $name  (DASH video + DASH image track + VTT + HLS image playlists + HLS video)"
}

# Process existing files on start
shopt -s nullglob
for f in "$IN"/*.mp4 "$IN"/*.mkv "$IN"/*.mov; do
  process_file "$f" || echo "[generator] Failed: $f"
done

# Watch for new files
echo "[generator] Watching $IN ..."
inotifywait -m -e close_write,create,move "$IN" | while read -r dir event file; do
  case "$file" in
    *.mp4|*.mkv|*.mov)
      process_file "$dir/$file" || echo "[generator] Failed: $dir/$file"
      ;;
    *) ;;
  esac
done