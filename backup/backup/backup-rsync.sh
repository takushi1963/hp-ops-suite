#!/bin/bash
#
# Name    : backup-rsync.sh
# Version : 2.0.0
# Updated : 2026-01-06
#
# Purpose :
#   - rsync で / を差分バックアップする（NAS /mnt/backup）
#   - スナップショット方式（前回を --link-dest でハードリンク化）
#   - ログを /var/log/backup に保存し、状況把握を容易にする
#
# Usage :
#   - 手動実行（root）: sudo /usr/local/bin/backup-rsync.sh
#
# Systemd :
#   - backup-rsync.service
#   - backup-rsync.timer
#
# Notes :
#   - /mnt/backup がマウントされていない場合は中止
#   - 実行中 I/O が増えるため、深夜運用推奨
#

set -euo pipefail

### 設定 ###########################################################

HOST="$(hostname)"
DATE_TAG="$(date '+%Y%m%d-%H%M%S')"

BACKUP_ROOT="/mnt/backup/rsync"
DEST_BASE="${BACKUP_ROOT}/${HOST}"
DEST="${DEST_BASE}/${DATE_TAG}"
LATEST_LINK="${DEST_BASE}/latest"

LOG_DIR="/var/log/backup"
LOG_FILE="${LOG_DIR}/backup-rsync-${DATE_TAG}.log"

SRC="/"

# 除外（OS差分バックアップの定番）
EXCLUDES=(
  "--exclude=/proc/*"
  "--exclude=/sys/*"
  "--exclude=/dev/*"
  "--exclude=/run/*"
  "--exclude=/tmp/*"
  "--exclude=/mnt/backup/*"
  "--exclude=/media/*"
  "--exclude=/lost+found"
  "--exclude=/swapfile"
)

###################################################################

mkdir -p "$DEST_BASE"
mkdir -p "$LOG_DIR"

exec > >(tee -a "$LOG_FILE") 2>&1

echo "========================================"
echo " backup-rsync.sh started"
echo " Host      : $HOST"
echo " Source    : $SRC"
echo " Dest      : $DEST"
echo " Start     : $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================"
echo

# --- mount check ---
if ! mount | grep -q "on /mnt/backup "; then
  echo "ERROR: /mnt/backup is not mounted"
  exit 1
fi

# --- previous snapshot (link-dest) ---
LINK_DEST_OPT=()
if [[ -L "$LATEST_LINK" ]] && [[ -d "$LATEST_LINK" ]]; then
  PREV="$(readlink -f "$LATEST_LINK" || true)"
  if [[ -n "${PREV:-}" ]] && [[ -d "$PREV" ]]; then
    echo "Previous snapshot: $PREV"
    LINK_DEST_OPT=( "--link-dest=$PREV" )
  fi
fi

# --- create snapshot dir ---
mkdir -p "$DEST"

START_TIME=$(date +%s)

echo "Running rsync..."
rsync -aHAX --numeric-ids --delete --delete-excluded \
  "${EXCLUDES[@]}" \
  "${LINK_DEST_OPT[@]}" \
  "$SRC" "$DEST" || {
    echo "ERROR: rsync failed (see log)."
    exit 1
  }

# --- update latest symlink atomically ---
ln -sfn "$DEST" "$LATEST_LINK"

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

echo
echo "========================================"
echo " backup-rsync.sh completed"
echo " End       : $(date '+%Y-%m-%d %H:%M:%S')"
echo " Duration  : $((ELAPSED / 60)) min $((ELAPSED % 60)) sec"
echo " Latest    : $LATEST_LINK -> $(readlink -f "$LATEST_LINK" || echo '(unknown)')"
echo "========================================"

exit 0
