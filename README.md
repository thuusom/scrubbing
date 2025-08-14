## CryptoGuard Scrubbing - Streaming Demo

This project demonstrates a local video processing and streaming workflow with three components:

- generator: Encodes a local input video into DASH and HLS, generates thumbnails (VTT and tiled sprites), and injects DASH image tracks.
- streamer: NGINX server that serves the processed media with correct MIME types and CORS.
- player: A Shaka Player UI page to preview different delivery modes (Local DASH + sprites, Local HLS + sprites, Local DASH + VTT, Remote Akamai DASH).

### Component details

- generator
  - Watches `media/input/` for new video files (mp4/mkv/mov)
  - Outputs to `media/output/<name>/`
  - Produces:
    - DASH with CMAF segments: `stream.mpd`, `init-video-*.mp4`, `chunk-video-*-00001.m4s`, ...
    - Injected DASH image track into MPD referencing `thumbs/thumb-$Number$.jpg`
    - HLS VOD (TS): `hls/stream.m3u8`, `hls/chunk-00000.ts`, `hls/master.m3u8`
    - Thumbnails:
      - Individual JPEGs: `thumbs/thumb-1.jpg` ...
      - WebVTT (file-per-thumb): `thumbs/thumbs.vtt`
      - Sprite sheet(s): `thumbs/sprites/sprite-1.jpg` (+ optional more)
      - Sprite VTT with `#xywh`: `thumbs/thumbs_sprites.vtt`
  - Tunables via environment:
    - `THUMB_EVERY_SEC` (default 2), `THUMB_WIDTH` (default 320)
    - `SPRITES_COLUMNS` (default 10), `SPRITES_ROWS` (default 10)

- streamer
  - Serves files from `media/output/` on port 8080
  - CORS is enabled with `always` so the player on 8081 can fetch assets
  - MIME types for `.mpd`, `.m3u8`, `.ts`, `.m4s`, `.vtt`, `.jpg` are configured

- player
  - Accessible on port 8081
  - Dropdown switches between:
    1. Local (MPD + VTT thumbnails)
    2. Local (DASH stream + image thumbnails)
    3. Local (HLS stream + image thumbnails)
    4. Remote Akamai (DASH stream + image thumbnails)
  - For consistent previews (incl. Safari), local options also add the sprite-based VTT

### Getting started

Prereqs: Docker + docker compose.

1. Put a test file at `media/input/video.mp4` (or `.mkv`/`.mov`).
2. Start the stack:

```sh
docker compose up -d --build
```

3. Open the player:

- Player UI: `http://localhost:8081/`
- Streamed media served by streamer: `http://localhost:8080/video/`

4. Switch between delivery modes using the dropdown.

### Stopping the stack

```sh
docker compose down
```

### How each container is constructed

- generator (`generator/Dockerfile`)
  - Alpine base with `ffmpeg`, `inotify-tools`, `bash`, `coreutils`, `jq`, `dos2unix`, `imagemagick`
  - Entrypoint `run.sh` performs one-time processing for existing files, then watches for new files
  - Uses ffmpeg for DASH and HLS, writes thumbnails, builds sprites via ImageMagick `montage`, and updates MPD for image tracks

- streamer (`streamer/nginx.conf`)
  - NGINX serving `/usr/share/nginx/html` mapped to `media/output`
  - Adds CORS headers with `always` so errors also include CORS
  - Registers MIME types for DASH/HLS/VTT/JPEG

- player (`player/Dockerfile` + `player/index.html`)
  - NGINX serves a single-page Shaka UI player
  - JS loads Shaka, initializes, and switches sources based on dropdown/URL
  - Uses sprite-based VTT for local modes to ensure reliable thumbnails across browsers

### TODO / Improvements

- Add multi-bitrate ladders for HLS/DASH and proper master manifests
- Package CMAF HLS (`.m4s`) instead of TS for HLS for modern pipelines
- Extract true duration and generate exact VTT end-times from MPD timelines
- Expose more tunables (bitrate, resolution) via env and/or Makefile
- Replace polling/fetch for VTT with direct Image Tracks when Shaka reliably surfaces them for all sources
- Add health-check endpoints and better logging
- Add CI to lint and validate manifests, and run an E2E smoke test

