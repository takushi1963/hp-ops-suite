#!/bin/bash
#
# backup_rsync.sh
# Version : 2.1.0
# Updated : 2026-01-05
# Purpose : 日次 rsync バックアップ（月曜はスキップ、flock による排他制御）
#
# ---- 変更履歴 ----------------------------------------------------
# 2.1.0 2026-01-05
#   ・CSV 出力順序の修正（END_TIME / ELAPSED 未定義問題を修正）
#   ・rsync の exclude 指定で brace 展開の罠（余分な空白）を修正
#   ・月曜スキップ（SKIP）およびロック中止（LOCK）を CSV に記録
#   ・NAS(CIFS) 環境で I/O error が出やすい /etc/alternatives を除外
#
# 2.0.0 2026-01-04
#   ・初期安定版
#   ・rsync / dd の同時実行防止（flock）を追加
#   ・月曜スキップ制御を追加
#   ・実行ログおよび CSV（実行時間）出力を追加
# -----------------------------------------------------------------
#

set -Eeuo pipefail

# ===== 基本設定 =====
LOCK="/run/backup.lock"
LOGDIR="/var/log/backup"
LOGFILE="$LOGDIR/rsync.log"
RSYNC_SRC="/"
RSYNC_DST="/mnt/backup/rsync"
CSV="/var/log/backup/rsync_time.csv"

mkdir -p "$LOGDIR"

# ===== 開始時刻記録 =====
START_EPOCH=$(date +%s)
START_TIME=$(date "+%Y-%m-%d %H:%M:%S")
echo "===== rsync バックアップ開始 [$START_TIME] =====" >> "$LOGFILE"

# ===== CSV 初期化（ヘッダが無ければ作成）=====
[ -f "$CSV" ] || echo "date,start,end,elapsed_sec,result" >> "$CSV"

# ===== 月曜は rsync をスキップ =====
if [ "$(date +%u)" -eq 1 ]; then
  echo "[INFO] 月曜のため rsync をスキップ" >> "$LOGFILE"
  echo "$(date +%F),$START_TIME,$(date '+%Y-%m-%d %H:%M:%S'),0,SKIP" >> "$CSV"
  exit 0
fi

# ===== ロック取得（dd / rsync の同時実行防止）=====
exec 9>"$LOCK" || exit 1

if ! flock -n 9; then
  echo "[WARN] 他のバックアップが実行中のため rsync を中止" >> "$LOGFILE"
  echo "$(date +%F),$START_TIME,$(date '+%Y-%m-%d %H:%M:%S'),0,LOCK" >> "$CSV"
  exit 0
fi

exec 200>/run/ops-backup.lock
flock -n 200 || { echo "Common backup lock busy" >&2; exit 75; }
mountpoint -q /mnt/backup || { echo "Backup mount unavailable" >&2; exit 1; }

# ===== rsync 実行 =====
# /etc/alternatives は NAS(CIFS) で symlink の I/O error が出やすいため除外
if ! rsync -aAXH --delete \
  --numeric-ids \
  --exclude={"/etc/alternatives/*","/dev/*","/proc/*","/sys/*","/tmp/*","/run/*","/mnt/*","/media/*","/lost+found"} \
  "$RSYNC_SRC" "$RSYNC_DST" >> "$LOGFILE" 2>&1
then
  END_EPOCH=$(date +%s)
  END_TIME=$(date "+%Y-%m-%d %H:%M:%S")
  ELAPSED=$((END_EPOCH - START_EPOCH))
  echo "[WARN] rsync 失敗（所要時間 ${ELAPSED} 秒）" >> "$LOGFILE"
  echo "$(date +%F),$START_TIME,$END_TIME,$ELAPSED,FAIL" >> "$CSV"
  echo "===== rsync バックアップ終了 [$END_TIME] (所要 ${ELAPSED} 秒) =====" >> "$LOGFILE"
  echo "" >> "$LOGFILE"
  exit 1
fi

# ===== 正常終了処理 =====
END_EPOCH=$(date +%s)
ELAPSED=$((END_EPOCH - START_EPOCH))
END_TIME=$(date "+%Y-%m-%d %H:%M:%S")

echo "$(date +%F),$START_TIME,$END_TIME,$ELAPSED,OK" >> "$CSV"
echo "===== rsync バックアップ終了 [$END_TIME] (所要 ${ELAPSED} 秒) =====" >> "$LOGFILE"
echo "" >> "$LOGFILE"
