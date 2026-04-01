# ROLE: UNKNOWN
#!/bin/bash
# ============================================================
# File    : /usr/local/bin/wav-cleanup.sh
# Version : 1.1.0
# Updated : 2026-04-01
#
# Purpose :
#   wav_raw 配下の古いWAVと .part ファイルを自動削除する
#
# Policy :
#   - wav_raw は 48時間を超えたら削除
#   - 録音途中の .part は削除
#   - events 系は触らない
#
# Notes :
#   - mtime(日単位)ではなく mmin(分単位) を使う
#   - Linux の -mtime +3 は感覚より遅く効くため不採用
# ============================================================

set -u

TARGET="/home/taku/recordings/wav_raw"
LOGFILE="/var/log/wav-cleanup.log"

# ------------------------------------------------------------
# 前提確認
# ------------------------------------------------------------
if [ ! -d "$TARGET" ]; then
  echo "[$(date '+%F %T')] [WARN] target not found: $TARGET" >> "$LOGFILE"
  exit 0
fi

# ------------------------------------------------------------
# 削除前件数
# ------------------------------------------------------------
OLD_WAV_COUNT_BEFORE=$(find "$TARGET" -type f -name "*.wav" -mmin +2880 2>/dev/null | wc -l)
PART_COUNT_BEFORE=$(find "$TARGET" -type f -name "*.part" 2>/dev/null | wc -l)

# ------------------------------------------------------------
# 48時間超の WAV を削除
# ------------------------------------------------------------
find "$TARGET" -type f -name "*.wav" -mmin +2880 -delete

# ------------------------------------------------------------
# 録音途中の .part を削除
# ------------------------------------------------------------
find "$TARGET" -type f -name "*.part" -delete

# ------------------------------------------------------------
# 実行後サイズ取得
# ------------------------------------------------------------
CURRENT_SIZE=$(du -sh "$TARGET" 2>/dev/null | awk '{print $1}')

# ------------------------------------------------------------
# ログ出力
# ------------------------------------------------------------
echo "[$(date '+%F %T')] [OK] cleanup done : deleted_old_wav=${OLD_WAV_COUNT_BEFORE}, deleted_part=${PART_COUNT_BEFORE}, current_size=${CURRENT_SIZE}" >> "$LOGFILE"

exit 0
