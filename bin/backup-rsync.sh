#!/bin/bash
# ROLE: BACKUP
# ROLE: BACKUP
# ============================================================
# File    : backup-rsync.sh
# Version : 2.2.0-A+++
# Updated : 2026-02-19
#
# 目的 :
#   Daily NAS rsync Backup（安定設計版）
#
# 機能 :
#   - NAS未マウント時の自動再マウント（最大3回）
#   - mount確認後のみ rsync 実行（誤書込防止）
#   - 対象限定バックアップ（生成物除外）
#   - 結果を JSON で保存（監視/ダッシュボード用）
#   - journal へ明示ログ出力
#
# 設計方針 :
#   - /home/taku 丸ごとはバックアップしない
#   - 仮想環境・node_modules・一時録音は除外
#   - symlink 依存構造を持ち込まない
#
# マウント :
#   - Mount point : /mnt/backup
#   - Share       : //192.168.0.10/HPBackup
#   - Status JSON : /var/log/backup/rsync.last_status.json
# ============================================================

set -u

LOG="/var/log/backup/rsync.log"
rsync ... >> "$LOG" 2>&1




DEST="/mnt/backup/hp-adsb"
MOUNT_POINT="/mnt/backup"

STATUS_DIR="/var/log/backup"
STATUS_JSON="${STATUS_DIR}/rsync.last_status.json"

mkdir -p "$STATUS_DIR"

ts_start="$(date -Is)"
host="$(hostname)"
result="NG"
reason=""
rc=0

log() { echo "$@"; logger -t backup-rsync "$@"; }

write_json() {
  local ts_end="$(date -Is)"
  cat >"$STATUS_JSON" <<EOF
{
  "ts_start": "${ts_start}",
  "ts_end": "${ts_end}",
  "host": "${host}",
  "dest": "${DEST}",
  "mount_point": "${MOUNT_POINT}",
  "result": "${result}",
  "reason": "${reason}",
  "exit_code": ${rc}
}
EOF
}

log "[INFO] backup started at ${ts_start}"

# ------------------------------------------------------------
# 1) NAS マウント確認（最大3回）
# ------------------------------------------------------------
if ! mountpoint -q "$MOUNT_POINT"; then
  log "[WARN] mount not available. attempting remount..."
  for i in 1 2 3; do
    mount "$MOUNT_POINT" >/dev/null 2>&1 || true
    sleep 3
    if mountpoint -q "$MOUNT_POINT"; then
      log "[INFO] remount success (try=${i})"
      break
    fi
    log "[WARN] remount retry failed (try=${i})"
  done
fi

# ------------------------------------------------------------
# 2) 再確認
# ------------------------------------------------------------
if ! mountpoint -q "$MOUNT_POINT"; then
  reason="backup mount not available"
  rc=1
  log "[ERROR] ${reason}"
  result="NG"
  write_json
  exit 1
fi

log "[INFO] NAS mount confirmed"

# ------------------------------------------------------------
# 3) バックアップ先準備
# ------------------------------------------------------------
mkdir -p "$DEST" || true

# ------------------------------------------------------------
# 4) 対象限定バックアップ実行
# ------------------------------------------------------------

# ---- scripts
rsync -a --delete \
  /home/taku/scripts/ \
  "$DEST/scripts/" || rc=$?

# ---- OPS Git
rsync -a --copy-links --delete \
  --exclude="systemd/" \
  /home/taku/ops-git/ \
  "$DEST/ops-git/" || rc=$?

# ---- recordings (events)
rsync -a --delete \
  /home/taku/recordings/events/ \
  "$DEST/recordings/events/" || rc=$?

# ---- recordings (data)
rsync -a --delete \
  /home/taku/recordings/data/ \
  "$DEST/recordings/data/" || rc=$?

# ------------------------------------------------------------
# 5) 結果処理
# ------------------------------------------------------------
if [ ${rc} -eq 0 ]; then
  result="OK"
  reason=""
  log "[OK] rsync backup completed"
else
  result="NG"
  reason="rsync failed"
  log "[ERROR] rsync failed (exit=${rc})"
fi

write_json
exit ${rc}
