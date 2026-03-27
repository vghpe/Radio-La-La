#!/bin/bash
# radio-stations.sh — Shared station definitions sourced by all radio scripts.
# Add new stations here; all scripts will pick them up automatically.

RADIO_STATIONS="fip kcrw kexp"

get_stream_url() {
  case "$1" in
    fip)  echo "https://icecast.radiofrance.fr/fip-hifi.aac" ;;
    kcrw) echo "https://streams.kcrw.com/e24_mp3" ;;
    kexp) echo "https://kexp.streamguys1.com/kexp160.aac" ;;
    *)    echo "" ;;
  esac
}

get_station_name() {
  case "$1" in
    fip)  echo "FIP" ;;
    kcrw) echo "KCRW" ;;
    kexp) echo "KEXP" ;;
    *)    echo "" ;;
  esac
}
