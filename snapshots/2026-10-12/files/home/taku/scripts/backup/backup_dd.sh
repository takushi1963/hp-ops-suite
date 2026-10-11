#!/bin/bash
#
# backup_dd.sh
# Version : 2.1.0
# Updated : 2026-01-05
# Purpose : 週次ディスクイメージバックアップ（月曜のみ、flock による排他制御）
#
# ---- 変更履歴 ----------------------------------------------------
# 2.1.0 2026-01-05
#   ・notify_fail() 未定義による実行時エラーを修正
#   ・LOCK / 容量不足 / SMART 失敗 / FAIL を CSV に記録
#   ・バックアップ先ディレクトリを自動作成
#   ・CSV 出力の一貫性を改善
#
# 2.0.0 2026-01-04
#   ・初期安定版
#   ・rsync / dd 同時実行防止（flock）を追加
#   ・実行ログおよび CSV（実行時間）出力を追加
#   ・空き容量チェックおよび SMART 簡易チェックを追加
# -----------------------------------------------------------------
#

set -Eeuo pipefail

# ===== 基本設定 =====
LOCK="/run/backup.lock"
LOGDIR="/var/log/backup"
LOGFILE="$LOGDIR/dd.log"
SRC_DEV="/dev/sda"
DST_IMG="/mnt/backup/dd/system_$(date +%Y%m%d).img.gz"
CSV="/var/log/backup/dd_time.csv"
MIN_FREE_GB=50

# ===== 失敗時のみ通知 =====
MAIL_TO="taku"
HOST="$(hostname)"
notify_fail() {
  local msg="$1"
  if command -v mail >/dev/null 2>&1; then
    echo "$msg" | mail -s "[バックアップ][DD][失敗] $HOST" "$MAIL_TO"
  fi
}

mkdir -p "$LOGDIR"


# ===== 開始時刻記録 =====
START_EPOCH=$(date +%s)
START_TIME=$(date "+%Y-%m-%d %H:%M:%S")
echo "===== dd バックアップ開始 [$START_TIME] =====" >> "$LOGFILE"

[ -f "$CSV" ] || echo "date,start,end,elapsed_sec,result" >> "$CSV"

# ===== ロック取得（rsync / dd 排他）=====
exec 9>"$LOCK" || exit 1
if ! flock -w 21600 9; then
  echo "[WARN] 他のバックアップが実行中のため dd を中止" >> "$LOGFILE"
  echo "$(date +%F),$START_TIME,$(date '+%Y-%m-%d %H:%M:%S'),0,LOCK" >> "$CSV"
  exit 75
fi

exec 200>/run/ops-backup.lock
flock -w 21600 200 || { echo "Common backup lock busy" >&2; exit 75; }
mountpoint -q /mnt/backup || { echo "Backup mount unavailable" >&2; exit 1; }

# ===== 空き容量チェック（dd 実行前）=====
FREE_GB=$(df -BG "$(dirname "$DST_IMG")" | awk 'NR==2 {gsub("G","",$4); print $4}')
if [ "${FREE_GB:-0}" -lt "$MIN_FREE_GB" ]; then
  msg="空き容量不足のため dd 中止 (${FREE_GB}GB < ${MIN_FREE_GB}GB)"
  echo "[WARN] $msg" >> "$LOGFILE"
  echo "$(date +%F),$START_TIME,$(date '+%Y-%m-%d %H:%M:%S'),0,NO_SPACE" >> "$CSV"
  notify_fail "$msg"
  exit 1
fi

# ===== SMART 簡易チェック（dd 実行前）=====
if command -v smartctl >/dev/null 2>&1; then
  if ! smartctl -H "$SRC_DEV" | grep -q "PASSED"; then
    msg="SMART ヘルスチェック失敗 ($SRC_DEV)"
    echo "[WARN] $msg" >> "$LOGFILE"
    echo "$(date +%F),$START_TIME,$(date '+%Y-%m-%d %H:%M:%S'),0,SMART_FAIL" >> "$CSV"
    notify_fail "$msg"
    exit 1
  fi
fi

# ===== dd 実行 =====
[ -b "$SRC_DEV" ] || { echo "Not a block device" >&2; exit 1; }
mkdir -p "$(dirname "$DST_IMG")"
[ ! -e "$DST_IMG" ] || { echo "Refusing image overwrite" >&2; exit 1; }
FINAL_IMG="$DST_IMG"
DST_IMG="${FINAL_IMG}.partial.$$"
STARTED_ISO=$(date -Is)
finish_status() {
  local code=$? result=NG reason='Weekly DD failed; partial output retained'
  trap - EXIT
  if [ "$code" -eq 0 ]; then result=OK; reason='Weekly DD pipeline completed; restore not tested'; fi
  if ! /usr/bin/python3 /usr/local/lib/ops-dashboard-repair/collector.py write-backup dd "$STARTED_ISO" "$(date -Is)" "$(hostname)" "$FINAL_IMG" "$result" "$reason" "$code"; then
    [ "$code" -ne 0 ] || code=1
  fi
  exit "$code"
}
trap finish_status EXIT
if ! dd if="$SRC_DEV" bs=64M status=progress | gzip -1 > "$DST_IMG"; then
  END_EPOCH=$(date +%s)
  END_TIME=$(date "+%Y-%m-%d %H:%M:%S")
  ELAPSED=$((END_EPOCH - START_EPOCH))
  msg="dd 実行中にエラーが発生 ($DST_IMG)"
  echo "[WARN] $msg" >> "$LOGFILE"
  echo "$(date +%F),$START_TIME,$END_TIME,$ELAPSED,FAIL" >> "$CSV"
  notify_fail "$msg"
  echo "===== dd バックアップ終了 [$END_TIME] (所要 ${ELAPSED} 秒) =====" >> "$LOGFILE"
  echo "" >> "$LOGFILE"
  exit 1
fi

mv -- "$DST_IMG" "$FINAL_IMG"
DST_IMG="$FINAL_IMG"
sync

# ===== 正常終了処理 =====
END_EPOCH=$(date +%s)
ELAPSED=$((END_EPOCH - START_EPOCH))
END_TIME=$(date "+%Y-%m-%d %H:%M:%S")

echo "$(date +%F),$START_TIME,$END_TIME,$ELAPSED,OK" >> "$CSV"
echo "===== dd バックアップ終了 [$END_TIME] (所要 ${ELAPSED} 秒) =====" >> "$LOGFILE"
echo "" >> "$LOGFILE"
