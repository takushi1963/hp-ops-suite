#!/bin/bash
# ============================================================
# File    : /usr/local/bin/wav-cleanup.sh
# Version : 1.2.0-A+++
# Updated : 2026-04-02
#
# Purpose :
#   wav_raw を時間ベースで削減（軽量運用）
#
# Policy :
#   - 24時間超は削除
#   - .part は即削除
# ============================================================

set -euo pipefail

TARGET="/home/taku/recordings/wav_raw"
LOGFILE="/var/log/wav-cleanup.log"

# 24時間以上削除
find "$TARGET" -type f -name "*.wav" -mmin +1440 -delete

# .part削除
find "$TARGET" -type f -name "*.part" -delete

SIZE=$(du -sh "$TARGET" | awk '{print $1}')

echo "[$(date '+%F %T')] [OK] cleanup size=${SIZE}" >> "$LOGFILE"
