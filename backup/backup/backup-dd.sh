#!/bin/bash
#
# Name    : backup-dd.sh
# Version : 2.0.0
# Updated : 2026-01-06
#
# Purpose :
#   - OSディスクを dd で丸ごとバックアップする
#   - 世代管理を行い、最後の正常状態を保持する
#
# Coverage :
#   - ブートローダ / パーティション / OS 全体
#
# Usage :
#   - 手動実行（root）: sudo /usr/local/bin/backup-dd.sh
#
# Systemd :
#   - backup-dd.service
#   - backup-dd.timer
#
# Notes :
#   - 非破壊設計（既存バックアップを自動削除しない）
#   - 実行時間は長い（数十分〜数時間）
#   - 実行中は I/O 負荷が高くなる
#

set -euo pipefail

### 設定 ###########################################################

SRC_DISK="/dev/sda"              # バックアップ元ディスク
BACKUP_ROOT="/mnt/backup/dd"     # 保存先ディレクトリ
LOG_DIR="/var/log/backup"

DATE_TAG="$(date '+%Y%m%d-%H%M%S')"
HOST="$(hostname)"
OUT_FILE="${BACKUP_ROOT}/${HOST}-dd-${DATE_TAG}.img.gz"
LOG_FILE="${LOG_DIR}/backup-dd-${DATE_TAG}.log"

###################################################################

mkdir -p "$BACKUP_ROOT"
mkdir -p "$LOG_DIR"

exec > >(tee -a "$LOG_FILE") 2>&1

echo "========================================"
echo " backup-dd.sh started"
echo " Host      : $HOST"
echo " Source    : $SRC_DISK"
echo " Output    : $OUT_FILE"
echo " Start     : $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================"
echo

# --- mount check ---
if ! mount | grep -q "on /mnt/backup "; then
    echo "ERROR: /mnt/backup is not mounted"
    exit 1
fi

# --- disk existence check ---
if [[ ! -b "$SRC_DISK" ]]; then
    echo "ERROR: source disk $SRC_DISK not found"
    exit 1
fi

# --- start backup ---
START_TIME=$(date +%s)

echo "Running dd backup..."
dd if="$SRC_DISK" bs=64M status=progress | gzip -c > "$OUT_FILE"

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

echo
echo "========================================"
echo " backup-dd.sh completed"
echo " End       : $(date '+%Y-%m-%d %H:%M:%S')"
echo " Duration  : $((ELAPSED / 60)) min $((ELAPSED % 60)) sec"
echo " File size : $(du -h "$OUT_FILE" | awk '{print $1}')"
echo "========================================"

exit 0
