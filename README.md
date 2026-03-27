# Radio Now Playing — SwiftBar + mpv

Listen to FIP, KCRW (Eclectic 24), and KEXP from your menu bar. Track info shows in the macOS Now Playing widget (Control Center) with full playback controls.

## What you get

- **macOS Now Playing integration** — current track, artist, and station name appear in Control Center, with play/pause via media keys
- **Compact menu bar** — single ♫ icon, no text taking up space
- **Station switching** — click the icon to switch between FIP, KCRW, KEXP
- **Spotify / Apple Music search** — one-click to find the song
- **Recently played tracks** — last 4 tracks in the dropdown

## Install

### 1. Install dependencies
```
brew install mpv socat jq
brew install --cask swiftbar
```

### 2. Set up the plugin folder

On first launch SwiftBar will ask you to pick a plugin folder (e.g. `~/SwiftBar`).
Copy these files there:

```
cp radio.5s.sh radio-ctl.sh radio-meta.sh ~/SwiftBar/
chmod +x ~/SwiftBar/radio.5s.sh ~/SwiftBar/radio-ctl.sh ~/SwiftBar/radio-meta.sh
```

SwiftBar auto-detects `radio.5s.sh` (refreshes every 5 seconds — it just reads a local file, very cheap).

## Usage

Click the ♫ icon in the menu bar → pick a station. That's it.

Under the hood:
- `radio-ctl.sh play fip|kcrw|kexp` — start or switch station
- `radio-ctl.sh pause` — toggle pause
- `radio-ctl.sh stop` — stop playback
- `radio-ctl.sh status` — show current state
- `radio-ctl.sh now` — show current track JSON
- `radio-ctl.sh api-now [station]` — fetch current track JSON directly from station API (bypasses cache)

The metadata daemon (`radio-meta.sh`) starts and stops automatically with playback.

## Debug In Terminal

From the project root, these commands are useful when debugging:

```bash
# Start FIP playback
./lib/radio-ctl.sh play fip

# Current track JSON (this is the main "what is playing now" command)
./lib/radio-ctl.sh now

# Direct station API JSON (bypasses local cache)
./lib/radio-ctl.sh api-now fip

# Compare cache vs live API for current station
echo "cache:" && ./lib/radio-ctl.sh now && echo "api:" && ./lib/radio-ctl.sh api-now

# Current track as plain text
./lib/radio-ctl.sh now | jq -r 'if .artist and .artist != "" then "\(.artist) – \(.title)" else .title end'

# Player status: playing|paused|stopped + station
./lib/radio-ctl.sh status

# Pause/resume
./lib/radio-ctl.sh pause

# Stop playback and metadata daemon
./lib/radio-ctl.sh stop
```

Direct FIP API check (without mpv/SwiftBar):

```bash
now=$(date +%s)
curl -s "https://api.radiofrance.fr/livemeta/pull/7" \
  | jq -r --argjson now "$now" '.steps | to_entries | map(select((.value.start // 0) <= $now)) | sort_by(.value.start // 0) | (map(select((.value.end // 4102444800) > $now)) | last // last) | "\(.value.authors // .value.performers // "") – \(.value.title // "")"'
```

Quick live watch while debugging:

```bash
while true; do ./lib/radio-ctl.sh now | jq -r '.station + ": " + ((.artist // "") + " – " + (.title // ""))'; sleep 2; done
```

## Stations

| Station | Stream |
|---------|--------|
| FIP | `https://icecast.radiofrance.fr/fip-hifi.aac` |
| KCRW (Eclectic 24) | `https://streams.kcrw.com/e24_mp3` |
| KEXP | `https://kexp.streamguys1.com/kexp160.aac` |

## Legacy plugins

The old per-station scripts (`fip.1m.sh`, `kcrw.1m.sh`, `kexp.1m.sh`) displayed track info in the menu bar text using Music.app for playback. They still work independently if you prefer that setup.

## Troubleshooting

**No sound**: Make sure `mpv` is installed (`brew install mpv`) and the stream URL is reachable.

**jq/socat not found**: Run `brew install jq socat`. On Apple Silicon these install to `/opt/homebrew/bin/` — the scripts handle this automatically.

**Nothing in Now Playing widget**: mpv should appear as its own card in Control Center. If it doesn't show, try `radio-ctl.sh stop` and `radio-ctl.sh play fip` again.

**SwiftBar not updating**: Check that `radio.5s.sh`, `radio-ctl.sh`, and `radio-meta.sh` are all in the same folder and executable.
