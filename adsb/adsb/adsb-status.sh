#!/bin/bash
#
# Name    : adsb-status.sh
# Version : 1.0.0
# Updated : 2026-01-06
#
# Purpose :
#   - ADS-B システム全体の稼働状況を一発表示
#
# Usage :
#   - 手動実行: ./adsb-status.sh
#

echo "========================================"
echo " ADS-B System Status"
echo " Host      : $(hostname)"
echo " Timestamp : $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================"
echo

echo "[Core]"
systemctl is-active readsb || true
systemctl is-active tar1090 || true
echo

echo "[Feeds]"
for s in fr24feed airplanes-feed ryukyu-feed; do
  printf " %-20s : " "$s"
  systemctl is-active "$s" || true
done
echo

echo "[MLAT]"
for s in mlat-client airplanes-mlat ryukyu-mlat; do
  printf " %-20s : " "$s"
  systemctl is-active "$s" || true
done
echo

echo "[Monitoring]"
for s in prometheus prometheus-node-exporter grafana-server; do
  printf " %-20s : " "$s"
  systemctl is-active "$s" || true
done
echo

echo "========================================"
