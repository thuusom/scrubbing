#!/usr/bin/env bash
set -euo pipefail

IN=/input
OUT=/output
THUMB_EVERY_SEC="${THUMB_EVERY_SEC:-2}"
THUMB_WIDTH="${THUMB_WIDTH:-320}"
SPRITES_COLUMNS="${SPRITES_COLUMNS:-10}"
SPRITES_ROWS="${SPRITES_ROWS:-10}"

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
    <EssentialProperty schemeIdUri="http://dashif.org/guidelines/trickmode" value="1"/>
    <SupplementalProperty schemeIdUri="http://dashif.org/guidelines/trickmode" value="1"/>
    <Representation id="img-1" bandwidth="5000" width="$width" height="$height" codecs="jpeg">
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

# Inject a DASH tiled thumbnails AdaptationSet that references sprite sheets
# The sprite sheets must be placed under: $dash_dir/$rep_id/tile_1.jpg ...
# And the AdaptationSet will reference: "$RepresentationID$/tile_$Number$.jpg"
inject_dash_tile_image_set () {
  local mpd="$1"          # $dash_dir/stream.mpd
  local cols="$2"         # SPRITES_COLUMNS
  local rows="$3"         # SPRITES_ROWS
  local cell_w="$4"       # individual thumb width
  local cell_h="$5"       # individual thumb height
  local dur="$6"          # THUMB_EVERY_SEC (seconds, integer)

  local sheet_w=$(( cols * cell_w ))
  local sheet_h=$(( rows * cell_h ))
  local rep_id="thumbnails_${cell_w}x${cell_h}"

  local tmp_as
  tmp_as="$(mktemp)"
  local per_sprite=$(( cols * rows ))
  local seg_dur=$dur
  cat >"$tmp_as" <<EOF
  <AdaptationSet mimeType="image/jpeg" contentType="image">
    <SegmentTemplate media="\$RepresentationID\$/tile_\$Number\$.jpg" timescale="1" duration="${seg_dur}" startNumber="1"/>
    <Representation bandwidth="12288" id="${rep_id}" width="${sheet_w}" height="${sheet_h}">
      <EssentialProperty schemeIdUri="http://dashif.org/thumbnail_tile" value="${cols}x${rows}"/>
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
  local dash_dir="$dest/dash"
  local hls_dir="$dest/hls"
  local thumbs_dir="$dest/thumbs"
  local sprites_dir="$dest/sprites"
  mkdir -p "$dash_dir" "$hls_dir" "$thumbs_dir" "$sprites_dir"

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
    -f dash "$dash_dir/stream.mpd" \
    || { echo "[generator] DASH encode failed for $src"; return 1; }

  [ -f "$dash_dir/stream.mpd" ] || return 1

  # -----------------------------
  # 2) Thumbnails (JPEG) — unpadded numbering to match MPD $Number$
  # -----------------------------
  rm -f "$thumbs_dir/"thumb-*.jpg
  ffmpeg -y -hide_banner -loglevel error -i "$src" \
    -vf "fps=1/${THUMB_EVERY_SEC},scale=${THUMB_WIDTH}:-2" \
    -q:v 2 "$thumbs_dir/thumb-%d.jpg"

  # Count thumbs
  local count
  count=$(ls -1 "$dest/thumbs"/thumb-*.jpg 2>/dev/null | wc -l | awk '{print $1}')
  if [[ "$count" -eq 0 ]]; then
    echo "[generator] No thumbnails created"; return 1
  fi

  # Dimensions from first thumb
  local first="$thumbs_dir/thumb-1.jpg"
  local dim
  dim=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$first" || echo "0,0")
  local t_width t_height
  t_width=$(echo "$dim" | cut -d, -f1)
  t_height=$(echo "$dim" | cut -d, -f2)

  # 3) Individual-image WebVTT (standard sidecar)
  local vtt="$thumbs_dir/thumbs.vtt"
  {
    echo "WEBVTT"
    echo ""
    local idx=1
    local start=0
    while [[ $idx -le $count ]]; do
      local end=$(( start + THUMB_EVERY_SEC ))
      echo "$idx"
      echo "$(fmt_hhmmss $start) --> $(fmt_hhmmss $end)"
      echo "thumb-${idx}.jpg"
      echo ""
      idx=$(( idx + 1 ))
      start=$end
    done
  } > "$vtt"

  # -----------------------------
  # 3b) Sprite sheets (tiled)
  # -----------------------------
  # Build multiple sprite images with fixed grid size (columns x rows)
  # and generate a corresponding VTT referencing subregions
  local sprite_dir="$sprites_dir"
  rm -rf "$sprite_dir" && mkdir -p "$sprite_dir"
  local cols="$SPRITES_COLUMNS" rows="$SPRITES_ROWS"
  local tile="${cols}x${rows}"
  local sprite_idx=0
  local idx=1
  local cell_w="$t_width" cell_h="$t_height"
  local per_sprite=$(( cols * rows ))
  local total="$count"
  while [[ $idx -le $total ]]; do
    sprite_idx=$(( sprite_idx + 1 ))
    # Collect up to per_sprite images
    local list=()
    local j=0
    while [[ $j -lt $per_sprite && $idx -le $total ]]; do
      list+=("$thumbs_dir/thumb-${idx}.jpg")
      idx=$(( idx + 1 ))
      j=$(( j + 1 ))
    done
    montage "${list[@]}" -tile "$tile" -geometry "+0+0" -background none "$sprite_dir/sprite-${sprite_idx}.jpg"
  done

  # Sprite-based VTT
  local svtt="$sprites_dir/thumbs_sprites.vtt"
  {
    echo "WEBVTT"
    echo ""
    local t=0
    local n=1
    local s=1
    while [[ $n -le $total ]]; do
      local sprite=$(( ((n-1)/per_sprite) + 1 ))
      local k=$(( (n-1) % per_sprite ))
      local r=$(( k / cols ))
      local c=$(( k % cols ))
      local x=$(( c * cell_w ))
      local y=$(( r * cell_h ))
      local t_end=$(( t + THUMB_EVERY_SEC ))
      echo "$n"
      echo "$(fmt_hhmmss $t) --> $(fmt_hhmmss $t_end)"
      echo "sprite-${sprite}.jpg#xywh=${x},${y},${cell_w},${cell_h}"
      echo ""
      t=$t_end
      n=$(( n + 1 ))
    done
  } > "$svtt"

  # 4) DASH Tiled Thumbnails AdaptationSet (sprites in AdaptationSet)
  # Copy sprite sheets into the DASH directory structure expected by SegmentTemplate
  local rep_id="thumbnails_${t_width}x${t_height}"
  local rep_dir="$dash_dir/$rep_id"
  rm -rf "$rep_dir" && mkdir -p "$rep_dir"
  # Map time slots to tile images; create tile_1..tile_count, repeating sprite sheets as needed
  local per_sprite=$(( SPRITES_COLUMNS * SPRITES_ROWS ))
  local k=1
  while [[ $k -le $count ]]; do
    local sheet_index=$(( ((k-1)/per_sprite) + 1 ))
    local sheet_path="$sprites_dir/sprite-${sheet_index}.jpg"
    if [[ ! -f "$sheet_path" ]]; then
      # Fallback to first sprite if missing
      sheet_path="$sprites_dir/sprite-1.jpg"
    fi
    cp -f "$sheet_path" "$rep_dir/tile_${k}.jpg"
    k=$(( k + 1 ))
  done
  inject_dash_tile_image_set "$dash_dir/stream.mpd" "$SPRITES_COLUMNS" "$SPRITES_ROWS" "$t_width" "$t_height" "$THUMB_EVERY_SEC"

  # 5) HLS Image Media Playlist (standard)
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