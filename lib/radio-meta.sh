#!/bin/bash
# radio-meta.sh — Background daemon that fetches station metadata and updates mpv
# Uses mpv's metadata-update events for instant response, with periodic fallback.
# Started/stopped by radio-ctl.sh. Do not run directly.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/radio-stations.sh"

SOCKET="/tmp/radio-mpv-socket"
STATE_DIR="$HOME/.radio"
STATION_FILE="$STATE_DIR/current-station"
TRACK_FILE="$STATE_DIR/current-track"
HISTORY_FILE="$STATE_DIR/recent-tracks"

JQ=$(command -v jq 2>/dev/null || echo "/opt/homebrew/bin/jq")
SOCAT=$(command -v socat 2>/dev/null || echo "/opt/homebrew/bin/socat")

LAST_DISPLAY=""
LAST_FETCH=0
MIN_FETCH_INTERVAL=10  # Don't hit APIs more than once per 10 seconds
FALLBACK_INTERVAL=15   # Periodic fallback fetch every 15s (covers API-only stations like KEXP/KCRW)
LAST_RELOAD=0          # Epoch of last stream reload (cooldown to prevent loops)

mpv_running() {
  [ -S "$SOCKET" ] && echo '{"command":["get_property","pid"]}' | "$SOCAT" - "$SOCKET" >/dev/null 2>&1
}

mpv_cmd() {
  echo "$1" | "$SOCAT" - "$SOCKET" 2>/dev/null
}

now_epoch() {
  date +%s
}

trigger_swiftbar_refresh() {
  open -g "swiftbar://refreshPlugin?name=radio" 2>/dev/null &
}

# Reload the live stream (reconnect fresh). Only used for dead-stream
# recovery (idle event). Resume-reload is handled by radio-live-resume.lua.
# Cooldown prevents re-entrant loops from events that loadfile generates.
reload_live() {
  local NOW
  NOW=$(now_epoch)
  local ELAPSED=$((NOW - LAST_RELOAD))
  if [ "$ELAPSED" -lt 5 ]; then
    return  # Within cooldown window, skip
  fi
  LAST_RELOAD=$NOW

  STATION=$(cat "$STATION_FILE" 2>/dev/null || echo "fip")
  URL=$(get_stream_url "$STATION")
  NAME=$(get_station_name "$STATION")
  if [ -n "$URL" ]; then
    mpv_cmd "{\"command\":[\"loadfile\",\"$URL\",\"replace\"]}"
    sleep 0.3
    mpv_cmd '{"command":["set_property","pause",false]}'
    mpv_cmd "{\"command\":[\"set_property\",\"force-media-title\",\"$NAME\"]}"
    LAST_FETCH=0  # Reset debounce so do_fetch runs immediately after
    do_fetch
  fi
  trigger_swiftbar_refresh
}

fetch_fip() {
  local DATA
  DATA=$(curl -sf --max-time 5 "https://api.radiofrance.fr/livemeta/pull/7")
  [ -z "$DATA" ] && return 1

  local NOW_TS KEYS NOW_KEY
  NOW_TS=$(date +%s)
  NOW_KEY=$("$JQ" -r --argjson now "$NOW_TS" '
    .steps
    | to_entries
    | map(select((.value.start // 0) <= $now))
    | sort_by(.value.start // 0)
    | (map(select((.value.end // 4102444800) > $now)) | last // last)
    | .key // ""
  ' <<< "$DATA" 2>/dev/null)
  [ -z "$NOW_KEY" ] && return 1

  local TITLE ARTIST ALBUM
  TITLE=$("$JQ" -r --arg k "$NOW_KEY" '.steps[$k].title // ""' <<< "$DATA")
  ARTIST=$("$JQ" -r --arg k "$NOW_KEY" '.steps[$k].authors // .steps[$k].performers // ""' <<< "$DATA")
  ALBUM=$("$JQ" -r --arg k "$NOW_KEY" '.steps[$k].titreAlbum // ""' <<< "$DATA")

  [ "$TITLE" = "null" ] && TITLE=""
  [ "$ARTIST" = "null" ] && ARTIST=""
  [ "$ALBUM" = "null" ] && ALBUM=""

  # Write current track
  "$JQ" -n --arg s "FIP" --arg t "$TITLE" --arg a "$ARTIST" --arg al "$ALBUM" \
    '{station:$s, title:$t, artist:$a, album:$al}' > "$TRACK_FILE.tmp" && mv "$TRACK_FILE.tmp" "$TRACK_FILE"

  # Write recent tracks
  local ALL_KEYS
  ALL_KEYS=$("$JQ" -r --argjson now "$NOW_TS" --arg nowkey "$NOW_KEY" '
    .steps
    | to_entries
    | map(select((.value.start // 0) <= $now))
    | sort_by(.value.start // 0)
    | map(.key)
    | map(select(. != $nowkey))
    | reverse
    | .[0:4]
    | .[]
  ' <<< "$DATA" 2>/dev/null)
  local RECENT="[]"
  while IFS= read -r KEY; do
    [ -z "$KEY" ] && continue
    local T A
    T=$("$JQ" -r --arg k "$KEY" '.steps[$k].title // ""' <<< "$DATA")
    A=$("$JQ" -r --arg k "$KEY" '.steps[$k].authors // .steps[$k].performers // ""' <<< "$DATA")
    [ "$T" = "null" ] || [ -z "$T" ] && continue
    [ "$A" = "null" ] && A=""
    RECENT=$("$JQ" --arg t "$T" --arg a "$A" '. + [{title:$t, artist:$a}]' <<< "$RECENT")
  done <<< "$ALL_KEYS"
  echo "$RECENT" > "$HISTORY_FILE.tmp" && mv "$HISTORY_FILE.tmp" "$HISTORY_FILE"

  # Return display string
  if [ -n "$ARTIST" ] && [ -n "$TITLE" ]; then
    echo "FIP: $ARTIST – $TITLE"
  elif [ -n "$TITLE" ]; then
    echo "FIP: $TITLE"
  else
    echo "FIP"
  fi
}

fetch_kcrw() {
  local DATA TRACKS
  DATA=$(curl -sf --max-time 5 "https://tracklist-api.kcrw.com/latest-playlist?show_title=Eclectic24")
  [ -z "$DATA" ] && return 1

  TRACKS=$("$JQ" -c '[ .[] | select((.title // "") != "" and (.artist // "") != "[BREAK]") ]' <<< "$DATA" 2>/dev/null)
  [ -z "$TRACKS" ] && return 1

  local TITLE ARTIST ALBUM SPOTIFY_ID
  TITLE=$("$JQ" -r '.[0].title // ""' <<< "$TRACKS" 2>/dev/null)
  ARTIST=$("$JQ" -r '.[0].artist // ""' <<< "$TRACKS" 2>/dev/null)
  ALBUM=$("$JQ" -r '.[0].album // ""' <<< "$TRACKS" 2>/dev/null)
  SPOTIFY_ID=$("$JQ" -r '.[0].spotify_id // ""' <<< "$TRACKS" 2>/dev/null)

  [ -z "$TITLE" ] && return 1
  [ "$ARTIST" = "null" ] && ARTIST=""
  [ "$ALBUM" = "null" ] && ALBUM=""
  [ "$SPOTIFY_ID" = "null" ] && SPOTIFY_ID=""

  "$JQ" -n --arg s "KCRW" --arg t "$TITLE" --arg a "$ARTIST" --arg al "$ALBUM" --arg sp "$SPOTIFY_ID" \
    '{station:$s, title:$t, artist:$a, album:$al, spotify_id:$sp}' > "$TRACK_FILE.tmp" && mv "$TRACK_FILE.tmp" "$TRACK_FILE"

  # Write recent tracks directly from API (5 entries)
  "$JQ" -c '.[1:6] | map({title, artist})' <<< "$TRACKS" > "$HISTORY_FILE.tmp" && mv "$HISTORY_FILE.tmp" "$HISTORY_FILE"

  if [ -n "$ARTIST" ] && [ -n "$TITLE" ]; then
    echo "KCRW: $ARTIST – $TITLE"
  elif [ -n "$TITLE" ]; then
    echo "KCRW: $TITLE"
  else
    echo "KCRW"
  fi
}

fetch_kexp() {
  local DATA
  DATA=$(curl -sf --max-time 5 "https://api.kexp.org/v2/plays/?limit=5")
  [ -z "$DATA" ] && return 1

  local IDX=0 TITLE="" ARTIST="" ALBUM="" NOW_IDX=-1
  while [ $IDX -lt 5 ]; do
    local TYPE
    TYPE=$("$JQ" -r ".results[$IDX].play_type" <<< "$DATA" 2>/dev/null)
    if [ "$TYPE" = "trackplay" ]; then
      TITLE=$("$JQ" -r ".results[$IDX].song // \"\"" <<< "$DATA")
      ARTIST=$("$JQ" -r ".results[$IDX].artist // \"\"" <<< "$DATA")
      ALBUM=$("$JQ" -r ".results[$IDX].album // \"\"" <<< "$DATA")
      NOW_IDX=$IDX
      break
    fi
    IDX=$((IDX + 1))
  done

  [ "$TITLE" = "null" ] && TITLE=""
  [ "$ARTIST" = "null" ] && ARTIST=""
  [ "$ALBUM" = "null" ] && ALBUM=""

  "$JQ" -n --arg s "KEXP" --arg t "$TITLE" --arg a "$ARTIST" --arg al "$ALBUM" \
    '{station:$s, title:$t, artist:$a, album:$al}' > "$TRACK_FILE.tmp" && mv "$TRACK_FILE.tmp" "$TRACK_FILE"

  # Recent tracks
  local RECENT="[]" COUNT=0
  IDX=0
  while [ $IDX -lt 5 ] && [ $COUNT -lt 4 ]; do
    if [ $IDX -ne $NOW_IDX ]; then
      local TYPE T A
      TYPE=$("$JQ" -r ".results[$IDX].play_type" <<< "$DATA" 2>/dev/null)
      if [ "$TYPE" = "trackplay" ]; then
        T=$("$JQ" -r ".results[$IDX].song // \"\"" <<< "$DATA")
        A=$("$JQ" -r ".results[$IDX].artist // \"\"" <<< "$DATA")
        [ "$T" != "null" ] && [ -n "$T" ] && \
          RECENT=$("$JQ" --arg t "$T" --arg a "$A" '. + [{title:$t, artist:$a}]' <<< "$RECENT")
        COUNT=$((COUNT + 1))
      fi
    fi
    IDX=$((IDX + 1))
  done
  echo "$RECENT" > "$HISTORY_FILE.tmp" && mv "$HISTORY_FILE.tmp" "$HISTORY_FILE"

  if [ -n "$ARTIST" ] && [ -n "$TITLE" ]; then
    echo "KEXP: $ARTIST – $TITLE"
  elif [ -n "$TITLE" ]; then
    echo "KEXP: $TITLE"
  else
    echo "KEXP"
  fi
}

# ─── Fetch and update ────────────────────────────────────────

do_fetch() {
  local NOW
  NOW=$(now_epoch)

  # Debounce: skip if we fetched recently
  local ELAPSED=$((NOW - LAST_FETCH))
  if [ "$ELAPSED" -lt "$MIN_FETCH_INTERVAL" ]; then
    return
  fi
  LAST_FETCH=$NOW

  # Exit if mpv is gone
  if ! mpv_running; then
    rm -f "$TRACK_FILE" "$HISTORY_FILE"
    exit 0
  fi

  STATION=$(cat "$STATION_FILE" 2>/dev/null || echo "")

  DISPLAY=""
  case "$STATION" in
    fip)  DISPLAY=$(fetch_fip)  ;;
    kcrw) DISPLAY=$(fetch_kcrw) ;;
    kexp) DISPLAY=$(fetch_kexp) ;;
  esac

  # Update mpv title if changed (this updates macOS Now Playing)
  if [ -n "$DISPLAY" ] && [ "$DISPLAY" != "$LAST_DISPLAY" ]; then
    ESCAPED=$(echo "$DISPLAY" | sed 's/\\/\\\\/g; s/"/\\"/g')
    mpv_cmd "{\"command\":[\"set_property\",\"force-media-title\",\"$ESCAPED\"]}"
    LAST_DISPLAY="$DISPLAY"
    trigger_swiftbar_refresh
  fi
}

# ─── Main: event listener with fallback timer ───────────────

# Do an immediate first fetch
do_fetch

# Ask mpv to observe metadata (ID 1) and pause state (ID 2)
mpv_cmd '{"command":["observe_property",1,"metadata"]}'
mpv_cmd '{"command":["observe_property",2,"pause"]}'

# Listen on the socket for events.
# NOTE: "while read -t N" exits the loop on timeout (non-zero exit),
# so we use "while true + if read" so timeouts still trigger do_fetch.
while true; do
  if IFS= read -r -t "$FALLBACK_INTERVAL" LINE <&3; then
    case "$LINE" in
      # Pause state changed: refresh UI (resume-reload is handled by
      # the Lua script radio-live-resume.lua inside mpv).
      *'"name":"pause"'*)
        trigger_swiftbar_refresh
        ;;
      # Stream died (EOF / idle): auto-reconnect to live
      *'"event":"idle"'*)
        STATION=$(cat "$STATION_FILE" 2>/dev/null || echo "")
        if [ -n "$STATION" ]; then
          reload_live
        fi
        ;;
      # Metadata update or new file loaded: fetch track info
      *'"event":"metadata-update"'*|*'"event":"file-loaded"'*)
        do_fetch
        ;;
    esac
  else
    # read timed out: fallback poll for API-driven stations
    if ! mpv_running; then break; fi
    do_fetch
  fi
done 3< <("$SOCAT" -u "$SOCKET" - 2>/dev/null)

# If mpv died, clean up
rm -f "$TRACK_FILE" "$HISTORY_FILE"
