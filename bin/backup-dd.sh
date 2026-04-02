# ROLE: BACKUP
#!/bin/bash
# ROLE: BACKUP
# ============================================================
# File    : backup-dd.sh
# Version : 1.0.0
# Updated : 2026-02-08
#
# Purpose :
#   月次 フルディスク dd バックアップ（最終防衛ライン）
#
# Policy :
#   - rsync とは同時実行しない
#   - 手動 or 月1 timer 実行
#   - 出力は NAS 上（gzip 圧縮）
# ============================================================

set -euo pipefail

SRC="/dev/sda"
OUT_DIR="/mnt/backup/dd"
OUT_FILE="${OUT_DIR}/$(hostname)_$(date +%F).img.gz"

mkdir -p "${OUT_DIR}"

echo "[INFO] dd backup started: ${OUT_FILE}"
dd if="${SRC}" bs=64M status=progress | gzip > "${OUT_FILE}"
echo "[OK] dd backup completed"
