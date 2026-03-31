#!/bin/bash

# <xbar.title>Radio Now Playing</xbar.title>
# <xbar.version>v2.0</xbar.version>
# <xbar.desc>Controls radio playback via mpv with station switching</xbar.desc>
# <xbar.dependencies>mpv,socat,jq,curl</xbar.dependencies>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CTL="$SCRIPT_DIR/../lib/radio-ctl.sh"
source "$SCRIPT_DIR/../lib/radio-stations.sh"
STATE_DIR="$HOME/.radio"
STATION_FILE="$STATE_DIR/current-station"
TRACK_FILE="$STATE_DIR/current-track"
HISTORY_FILE="$STATE_DIR/recent-tracks"

JQ=$(command -v jq 2>/dev/null || echo "/opt/homebrew/bin/jq")
SOCAT=$(command -v socat 2>/dev/null || echo "/opt/homebrew/bin/socat")
SOCKET="/tmp/radio-mpv-socket"
DISPLAY_MODE_FILE="$STATE_DIR/display-mode"
DISPLAY_MODE=$(cat "$DISPLAY_MODE_FILE" 2>/dev/null || echo "text")

# ─── Determine playback state ──────────────────────────────
PLAYING=false
PAUSED=false
STATION=""
STATION_NAME=""

if [ -S "$SOCKET" ] && echo '{"command":["get_property","pid"]}' | "$SOCAT" - "$SOCKET" >/dev/null 2>&1; then
  PLAYING=true
  STATION=$(cat "$STATION_FILE" 2>/dev/null || echo "")
  PAUSE_STATE=$(echo '{"command":["get_property","pause"]}' | "$SOCAT" - "$SOCKET" 2>/dev/null)
  if echo "$PAUSE_STATE" | grep -q '"data":true'; then
    PAUSED=true
  fi
fi

# Station display names
get_station_name() {
  case "$1" in
    fip)  echo "FIP" ;;
    kcrw) echo "KCRW" ;;
    kexp) echo "KEXP" ;;
    *)    echo "" ;;
  esac
}

STATION_NAME=$(get_station_name "$STATION")

# ─── Read current track metadata ───────────────────────────
TITLE=""
ARTIST=""
ALBUM=""
SPOTIFY_ID=""

if [ -f "$TRACK_FILE" ]; then
  TITLE=$("$JQ" -r '.title // ""' "$TRACK_FILE" 2>/dev/null)
  ARTIST=$("$JQ" -r '.artist // ""' "$TRACK_FILE" 2>/dev/null)
  ALBUM=$("$JQ" -r '.album // ""' "$TRACK_FILE" 2>/dev/null)
  SPOTIFY_ID=$("$JQ" -r '.spotify_id // ""' "$TRACK_FILE" 2>/dev/null)
  [ "$TITLE" = "null" ] && TITLE=""
  [ "$ARTIST" = "null" ] && ARTIST=""
  [ "$ALBUM" = "null" ] && ALBUM=""
fi

# ─── Menu bar line ────────────────────────────────────────
if [ "$PLAYING" = true ]; then
  if [ "$DISPLAY_MODE" = "text" ] && [ -n "$TITLE" ]; then
    LABEL="$TITLE"
    [ -n "$ARTIST" ] && LABEL="$ARTIST - $TITLE"
    # Strip pipes (break SwiftBar parsing)
    LABEL=$(printf '%s' "$LABEL" | tr '|' '-')
    if [ "$PAUSED" = true ]; then
      echo "⏸ $LABEL | size=12 length=30"
    else
      echo "♫ $LABEL | size=12 length=30"
    fi
  elif [ "$DISPLAY_MODE" = "artist" ] && [ -n "$ARTIST" ]; then
    LABEL=$(printf '%s' "$ARTIST" | tr '|' '-')
    if [ "$PAUSED" = true ]; then
      echo "⏸ $LABEL | size=12 length=20"
    else
      echo "♫ $LABEL | size=12 length=20"
    fi
  else
    if [ "$PAUSED" = true ]; then
      echo "⏸ | size=14"
    else
      echo "♫ | size=14"
    fi
  fi
else
  echo "♫ | sfcolor=#444444 size=14"
fi

echo "---"

# ─── Dropdown content ──────────────────────────────────────

if [ "$PLAYING" = true ] && [ -n "$STATION_NAME" ]; then
  # ─── Pause/Resume at the top ────────────────────────────
  if [ "$PAUSED" = true ]; then
    echo "▶ Resume | bash=$CTL param1=pause terminal=false refresh=true"
  else
    echo "⏸ Pause | bash=$CTL param1=pause terminal=false refresh=true"
  fi

  echo "---"

  if [ -n "$TITLE" ]; then
    # Artist – Title (standard "now playing" format)
    if [ -n "$ARTIST" ]; then
      TRACK_DISPLAY="$ARTIST – $TITLE"
    else
      TRACK_DISPLAY="$TITLE"
    fi
    echo "$TRACK_DISPLAY | size=13 bash=$CTL param1=copy terminal=false"
    echo "---"

    # Spotify / Apple Music search
    QUERY=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$ARTIST $TITLE" 2>/dev/null || echo "")
    if [ -n "$QUERY" ]; then
      # Use direct track link if spotify_id is available, otherwise search
      if [ -n "$SPOTIFY_ID" ] && [ "$SPOTIFY_ID" != "null" ]; then
        echo "Open in Spotify | href=spotify:track:$SPOTIFY_ID"
      else
        echo "Search on Spotify | href=spotify:search:$QUERY"
      fi
    fi
  else
    echo "Loading track info... | color=#aaaaaa size=11"
  fi

  echo "---"

  # ─── Station switcher ──────────────────────────────────
  for S in $RADIO_STATIONS; do
    N=$(get_station_name "$S")
    if [ "$S" = "$STATION" ]; then
      echo "● $N | size=12"
    else
      echo "  $N | bash=$CTL param1=play param2=$S terminal=false refresh=true size=12"
    fi
  done

  echo "---"

  # ─── Recently played (single jq call for all entries) ────
  if [ -f "$HISTORY_FILE" ]; then
    RECENT_COUNT=$("$JQ" 'length' "$HISTORY_FILE" 2>/dev/null || echo 0)
    if [ "$RECENT_COUNT" -gt 0 ] 2>/dev/null; then
      echo "Recently on $STATION_NAME | color=#777777 size=11"
      RECENT_LINES=$("$JQ" -r '.[] | [.artist//"", .title//""] | join("\t")' "$HISTORY_FILE" 2>/dev/null)
      IDX=0
      while IFS=$'\t' read -r RA RT; do
        [ -z "$RT" ] || [ "$RT" = "null" ] && { IDX=$((IDX+1)); continue; }
        [ "$RA" = "null" ] && RA=""
        if [ -n "$RA" ]; then
          COPY_TEXT="$RA – $RT"
        else
          COPY_TEXT="$RT"
        fi
        echo "$COPY_TEXT | color=#777777 size=11 bash=$CTL param1=copy-recent param2=$IDX terminal=false"
        IDX=$((IDX+1))
      done <<< "$RECENT_LINES"
      echo "---"
    fi
  fi

  # ─── Display mode ─────────────────────────────────────────
  echo "Show in menu bar | color=#777777 size=11"
  if [ "$DISPLAY_MODE" = "text" ]; then
    echo "● Track & artist | size=12"
  else
    echo "  Track & artist | bash=$CTL param1=display param2=text terminal=false refresh=true size=12"
  fi
  if [ "$DISPLAY_MODE" = "artist" ]; then
    echo "● Artist only | size=12"
  else
    echo "  Artist only | bash=$CTL param1=display param2=artist terminal=false refresh=true size=12"
  fi
  if [ "$DISPLAY_MODE" = "icon" ]; then
    echo "● Icon only | size=12"
  else
    echo "  Icon only | bash=$CTL param1=display param2=icon terminal=false refresh=true size=12"
  fi

else
  # Not playing
  echo "Pick a station | size=12"
  echo "---"
  for S in $RADIO_STATIONS; do
    N=$(get_station_name "$S")
    echo "▶ $N | bash=$CTL param1=play param2=$S terminal=false refresh=true size=12"
  done
fi

echo "---"
echo "Quit | bash=$CTL param1=quit terminal=false"
