#!/bin/bash
# radio-ctl.sh — Control script for radio playback via mpv
# Usage: radio-ctl.sh play fip|kcrw|kexp
#        radio-ctl.sh pause
#        radio-ctl.sh stop
#        radio-ctl.sh status
#        radio-ctl.sh now
#        radio-ctl.sh api-now [fip|kcrw|kexp]

SOCKET="/tmp/radio-mpv-socket"
STATE_DIR="$HOME/.radio"
STATION_FILE="$STATE_DIR/current-station"
TRACK_FILE="$STATE_DIR/current-track"
META_PID_FILE="$STATE_DIR/meta-daemon.pid"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPT_DIR"
source "$SCRIPT_DIR/radio-stations.sh"
SOCAT=$(command -v socat 2>/dev/null || echo "/opt/homebrew/bin/socat")
MPV=$(command -v mpv 2>/dev/null || echo "/opt/homebrew/bin/mpv")
JQ=$(command -v jq 2>/dev/null || echo "/opt/homebrew/bin/jq")

mkdir -p "$STATE_DIR"

trigger_swiftbar_refresh() {
  open -g "swiftbar://refreshPlugin?name=radio" 2>/dev/null &
}

notify() {
  osascript -e "display notification \"$1\" with title \"Radio La La\"" 2>/dev/null &
}

# Stream URLs and display names are sourced from radio-stations.sh

mpv_running() {
  [ -S "$SOCKET" ] && echo '{"command":["get_property","pid"]}' | "$SOCAT" - "$SOCKET" >/dev/null 2>&1
}

mpv_cmd() {
  echo "$1" | "$SOCAT" - "$SOCKET" 2>/dev/null
}

api_now() {
  local STATION="$1"
  local DATA=""
  local TITLE=""
  local ARTIST=""
  local ALBUM=""

  case "$STATION" in
    fip)
      DATA=$(curl -sf --max-time 8 "https://api.radiofrance.fr/livemeta/pull/7") || return 1
      NOW_TS=$(date +%s)
      TITLE=$("$JQ" -r --argjson now "$NOW_TS" '.steps | to_entries | map(select((.value.start // 0) <= $now)) | sort_by(.value.start // 0) | (map(select((.value.end // 4102444800) > $now)) | last // last) | .value.title // ""' <<< "$DATA" 2>/dev/null)
      ARTIST=$("$JQ" -r --argjson now "$NOW_TS" '.steps | to_entries | map(select((.value.start // 0) <= $now)) | sort_by(.value.start // 0) | (map(select((.value.end // 4102444800) > $now)) | last // last) | (.value.authors // .value.performers // "")' <<< "$DATA" 2>/dev/null)
      ALBUM=$("$JQ" -r --argjson now "$NOW_TS" '.steps | to_entries | map(select((.value.start // 0) <= $now)) | sort_by(.value.start // 0) | (map(select((.value.end // 4102444800) > $now)) | last // last) | .value.titreAlbum // ""' <<< "$DATA" 2>/dev/null)
      [ "$TITLE" = "null" ] && TITLE=""
      [ "$ARTIST" = "null" ] && ARTIST=""
      [ "$ALBUM" = "null" ] && ALBUM=""
      "$JQ" -n --arg s "FIP" --arg t "$TITLE" --arg a "$ARTIST" --arg al "$ALBUM" \
        '{station:$s, title:$t, artist:$a, album:$al, source:"api"}'
      ;;

    kcrw)
      DATA=$(curl -sf --max-time 8 "https://tracklist-api.kcrw.com/Music.json") || return 1
      TITLE=$("$JQ" -r '.title // ""' <<< "$DATA" 2>/dev/null)
      ARTIST=$("$JQ" -r '.artist // ""' <<< "$DATA" 2>/dev/null)
      ALBUM=$("$JQ" -r '.album // ""' <<< "$DATA" 2>/dev/null)
      [ "$TITLE" = "null" ] && TITLE=""
      [ "$ARTIST" = "null" ] && ARTIST=""
      [ "$ALBUM" = "null" ] && ALBUM=""
      "$JQ" -n --arg s "KCRW" --arg t "$TITLE" --arg a "$ARTIST" --arg al "$ALBUM" \
        '{station:$s, title:$t, artist:$a, album:$al, source:"api"}'
      ;;

    kexp)
      DATA=$(curl -sf --max-time 8 "https://api.kexp.org/v2/plays/?limit=5") || return 1
      TITLE=$("$JQ" -r '.results | map(select(.play_type=="trackplay")) | .[0].song // ""' <<< "$DATA" 2>/dev/null)
      ARTIST=$("$JQ" -r '.results | map(select(.play_type=="trackplay")) | .[0].artist // ""' <<< "$DATA" 2>/dev/null)
      ALBUM=$("$JQ" -r '.results | map(select(.play_type=="trackplay")) | .[0].album // ""' <<< "$DATA" 2>/dev/null)
      [ "$TITLE" = "null" ] && TITLE=""
      [ "$ARTIST" = "null" ] && ARTIST=""
      [ "$ALBUM" = "null" ] && ALBUM=""
      "$JQ" -n --arg s "KEXP" --arg t "$TITLE" --arg a "$ARTIST" --arg al "$ALBUM" \
        '{station:$s, title:$t, artist:$a, album:$al, source:"api"}'
      ;;

    *)
      return 1
      ;;
  esac
}

start_meta_daemon() {
  # Kill existing daemon if running
  stop_meta_daemon
  # Start new daemon in background
  nohup "$LIB_DIR/radio-meta.sh" >/dev/null 2>&1 &
  echo $! > "$META_PID_FILE"
}

stop_meta_daemon() {
  if [ -f "$META_PID_FILE" ]; then
    PID=$(cat "$META_PID_FILE" 2>/dev/null)
    if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
      kill "$PID" 2>/dev/null
    fi
    rm -f "$META_PID_FILE"
  fi
}

case "${1:-}" in
  play)
    STATION="${2:-fip}"
    STATION=$(echo "$STATION" | tr '[:upper:]' '[:lower:]')

    URL=$(get_stream_url "$STATION")
    NAME=$(get_station_name "$STATION")

    if [ -z "$URL" ]; then
      echo "Unknown station: $STATION (available: fip, kcrw, kexp)"
      exit 1
    fi

    # Write station + clear stale data BEFORE loadfile so the old daemon
    # can't race and fetch for the wrong station on the file-loaded event
    echo "$STATION" > "$STATION_FILE"
    printf '{"station":"%s","title":"","artist":"","album":""}\n' "$NAME" > "$TRACK_FILE"
    rm -f "$STATE_DIR/recent-tracks"

    if mpv_running; then
      # Switch stream on running mpv
      mpv_cmd "{\"command\":[\"loadfile\",\"$URL\",\"replace\"]}"
      mpv_cmd "{\"command\":[\"set_property\",\"force-media-title\",\"$NAME\"]}"
    else
      # Clean up stale socket
      rm -f "$SOCKET"
      # Launch mpv
      # reconnect_streamed: reconnect HTTP streams that don't support range
      # requests (icecast/AAC radio). On resume after pause or a dropped
      # connection mpv reconnects to the live position rather than failing.
      # reconnect_on_network_error: retry on transient network errors.
      "$MPV" \
        --no-video \
        --input-ipc-server="$SOCKET" \
        --really-quiet \
        --force-media-title="$NAME" \
        --demuxer-max-bytes=256KiB \
        --cache=yes \
        --stream-lavf-o=reconnect_streamed=1 \
        --stream-lavf-o-append=reconnect_on_network_error=1 \
        --script="$SCRIPT_DIR/radio-live-resume.lua" \
        "$URL" &
      # Wait for socket to appear
      for i in $(seq 1 20); do
        [ -S "$SOCKET" ] && break
        sleep 0.25
      done
    fi

    # Start metadata daemon (or restart if switching stations)
    start_meta_daemon
    trigger_swiftbar_refresh
    ;;

  pause)
    if mpv_running; then
      mpv_cmd '{"command":["cycle","pause"]}'
      trigger_swiftbar_refresh
    fi
    ;;

  stop)
    if mpv_running; then
      mpv_cmd '{"command":["quit"]}'
    fi
    stop_meta_daemon
    rm -f "$STATION_FILE" "$TRACK_FILE" "$SOCKET"
    # Also kill any stale daemon by name
    pkill -f "radio-meta.sh" 2>/dev/null
    trigger_swiftbar_refresh
    ;;

  status)
    if mpv_running; then
      STATION=$(cat "$STATION_FILE" 2>/dev/null || echo "")
      NAME=$(get_station_name "$STATION")
      PAUSED=$(echo '{"command":["get_property","pause"]}' | "$SOCAT" - "$SOCKET" 2>/dev/null | grep -o '"data":[a-z]*' | cut -d: -f2)
      if [ "$PAUSED" = "true" ]; then
        echo "paused|$STATION|$NAME"
      else
        echo "playing|$STATION|$NAME"
      fi
    else
      echo "stopped||"
    fi
    ;;

  now)
    if [ -f "$TRACK_FILE" ]; then
      cat "$TRACK_FILE"
    else
      echo '{}'
    fi
    ;;

  api-now)
    STATION="${2:-$(cat "$STATION_FILE" 2>/dev/null || echo "fip")}"
    STATION=$(echo "$STATION" | tr '[:upper:]' '[:lower:]')
    if ! api_now "$STATION"; then
      echo "Unknown station or API error: $STATION (available: fip, kcrw, kexp)" >&2
      exit 1
    fi
    ;;

  display)
    MODE="${2:-text}"
    echo "$MODE" > "$STATE_DIR/display-mode"
    trigger_swiftbar_refresh
    ;;

  copy)
    # Copy current track info to clipboard
    if [ -f "$TRACK_FILE" ]; then
      T=$("$JQ" -r '.title // ""' "$TRACK_FILE" 2>/dev/null)
      A=$("$JQ" -r '.artist // ""' "$TRACK_FILE" 2>/dev/null)
      [ "$T" = "null" ] && T=""
      [ "$A" = "null" ] && A=""
      if [ -n "$A" ] && [ -n "$T" ]; then
        printf '%s' "$A – $T" | pbcopy
        notify "$A – $T"
      elif [ -n "$T" ]; then
        printf '%s' "$T" | pbcopy
        notify "$T"
      fi
    fi
    ;;

  copy-recent)
    # Copy recent track by index to clipboard
    IDX="${2:-0}"
    HISTORY="$STATE_DIR/recent-tracks"
    if [ -f "$HISTORY" ]; then
      JQ=$(command -v jq 2>/dev/null || echo "/opt/homebrew/bin/jq")
      T=$("$JQ" -r ".[${IDX}].title // \"\"" "$HISTORY" 2>/dev/null)
      A=$("$JQ" -r ".[${IDX}].artist // \"\"" "$HISTORY" 2>/dev/null)
      [ "$T" = "null" ] && T=""
      [ "$A" = "null" ] && A=""
      if [ -n "$A" ] && [ -n "$T" ]; then
        printf '%s' "$A – $T" | pbcopy
        notify "$A – $T"
      elif [ -n "$T" ]; then
        printf '%s' "$T" | pbcopy
        notify "$T"
      fi
    fi
    ;;

  quit)
    # Stop player, clean up, and quit SwiftBar
    if mpv_running; then
      mpv_cmd '{"command":["quit"]}'
    fi
    stop_meta_daemon
    rm -f "$STATION_FILE" "$TRACK_FILE" "$SOCKET"
    pkill -f "radio-meta.sh" 2>/dev/null
    rm -f "$STATE_DIR/recent-tracks"
    osascript -e 'quit app "SwiftBar"' 2>/dev/null
    ;;

  *)
    echo "Usage: radio-ctl.sh {play <station>|pause|stop|status|now|api-now [station]|display <icon|text>}"
    echo "Stations: fip, kcrw, kexp"
    exit 1
    ;;
esac
