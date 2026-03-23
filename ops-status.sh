#!/bin/bash
#
# Name    : ops-status.sh
# Version : 1.2.0
# Updated : 2026-01-06
#
# Purpose :
#   - Backup / ADS-B / Audio 全系の状態を一発表示
#   - --json 指定時は機械可読な JSON を出力
#

set -euo pipefail

MODE="text"
if [[ "${1:-}" == "--json" ]]; then
  MODE="json"
fi

HOST="$(hostname)"
TS="$(date '+%Y-%m-%d %H:%M:%S')"

is_active() {
  local svc="$1"
  if systemctl is-active --quiet "$svc"; then
    echo "active"
  else
    echo "inactive"
  fi
}

run_text() {
  local cmd="$1"
  if [[ -x "$cmd" ]]; then
    "$cmd"
  else
    echo " $cmd not found or not executable"
  fi
}

if [[ "$MODE" == "text" ]]; then
  echo "========================================"
  echo " OPS Overall Status"
  echo " Host      : $HOST"
  echo " Timestamp : $TS"
  echo "========================================"
  echo

  echo "[Backup]"
  run_text /usr/local/bin/backup-status.sh
  echo

  echo "[ADS-B]"
  run_text /usr/local/bin/adsb-status.sh
  echo

  echo "[Audio]"
  run_text /usr/local/bin/audio-status.sh
  echo

  echo "========================================"
  exit 0
fi

# --- JSON output ---
cat <<JSON
{
  "meta": {
    "host": "$HOST",
    "timestamp": "$TS"
  },
  "backup": {
    "entrypoint": "/usr/local/bin/backup-status.sh",
    "exists": $( [[ -x /usr/local/bin/backup-status.sh ]] && echo true || echo false )
  },
  "adsb": {
    "services": {
      "readsb": "$(is_active readsb)",
      "tar1090": "$(is_active tar1090)",
      "fr24feed": "$(is_active fr24feed)",
      "airplanes-feed": "$(is_active airplanes-feed)",
      "ryukyu-feed": "$(is_active ryukyu-feed)"
    }
  },
  "audio": {
    "services": {
      "aircraft-recorder": "$(is_active aircraft-recorder)",
      "audio-adsb-realtime": "$(is_active audio-adsb-realtime)",
      "audio-monitor": "$(is_active audio-monitor)"
    }
  }
}
JSON
