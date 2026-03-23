#!/bin/bash
#
# Name    : audio-status.sh
# Version : 1.0.0
# Updated : 2026-01-06
#
# Purpose :
#   - Audio 系全体の稼働状況を一発表示
#

echo "========================================"
echo " Audio System Status"
echo " Host      : $(hostname)"
echo " Timestamp : $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================"
echo

for s in aircraft-recorder audio-adsb-realtime audio-monitor; do
  printf " %-22s : " "$s"
  systemctl is-active "$s" || true
done

echo
echo "[Logs]"
ls -ld /var/log/audio-monitor 2>/dev/null || echo " audio log dir not found"
echo "========================================"
