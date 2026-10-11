#!/bin/bash
# ROLE: BACKUP
# ============================================================
# File    : /usr/local/bin/backup-rsync.sh
# Version : 2.4.0-A+++
# Updated : 2026-04-07
#
# Purpose :
#   Daily NAS rsync Backup（誤書込防止・CIFS対策強化版）
#
# Notes :
#   - /mnt/backup が正しくマウントされている時だけ実行する
#   - mountpoint確認だけでなく、書込テストでも実体確認する
#   - NAS未マウント時は最大3回まで再マウントを試行する
#   - ローカル /mnt への誤書込を防ぐ
#   - CIFS/NAS で問題になりやすい owner/group/perms/acl/xattr は転送しない
#   - 結果を JSON に保存して監視に使えるようにする
#
# Backup Targets :
#   - /home/taku/scripts/
#   - /home/taku/ops-git/
#   - /home/taku/recordings/events/
#   - /home/taku/recordings/data/
#
# Output :
#   - Log        : /var/log/backup/rsync.log
#   - Status JSON: /var/log/backup/rsync.last_status.json
# ============================================================

set -u
set -o pipefail

# OPS repair: hold common backup lock for the complete job.
exec 200>/run/ops-backup.lock
flock -n 200 || { echo 'Another backup is running' >&2; exit 75; }

# ------------------------------------------------------------
# 固定値
# ------------------------------------------------------------
LOG="/var/log/backup/rsync.log"
STATUS_DIR="/var/log/backup"
STATUS_JSON="${STATUS_DIR}/rsync.last_status.json"

MOUNT_POINT="/mnt/backup"
DEST="${MOUNT_POINT}/hp-adsb"

HOSTNAME_STR="$(hostname)"
TS_START="$(date -Is)"

RESULT="NG"
REASON=""
RC=0

# CIFS/NAS 向け共通 rsync オプション
# -a は再帰・時刻保持などに有効
# owner/group/perms/acl/xattr は NAS で警告になりやすいので明示的に無効化
COMMON_RSYNC_OPTS=(
  -a
  --delete
  --no-perms
  --no-owner
  --no-group
  --no-acls
  --no-xattrs
)

# ------------------------------------------------------------
# 共通関数
# ------------------------------------------------------------
log() {
    local msg="$1"
    echo "$(date '+%F %T') ${msg}" | tee -a "${LOG}"
    logger -t backup-rsync "${msg}"
}

write_json() {
    local ts_end
    ts_end="$(date -Is)"
    /usr/bin/python3 /usr/local/lib/ops-dashboard-repair/collector.py write-backup rsync         "$TS_START" "$ts_end" "$HOSTNAME_STR" "$DEST" "$RESULT" "$REASON" "$RC"
}

ensure_dirs() {
    mkdir -p "${STATUS_DIR}"
    touch "${LOG}" 2>/dev/null || true
}

# ------------------------------------------------------------
# マウントポイント確認
# ------------------------------------------------------------
is_mount_ok() {
    mountpoint -q "${MOUNT_POINT}"
}

# ------------------------------------------------------------
# 実書込テスト
#   mountpoint だけでは不十分なケースに備える
# ------------------------------------------------------------
is_write_test_ok() {
    local testfile="${MOUNT_POINT}/.mount_test_backup_rsync.$$"

    if ! touch "${testfile}" >/dev/null 2>&1; then
        return 1
    fi

    sync >/dev/null 2>&1 || true

    if ! rm -f "${testfile}" >/dev/null 2>&1; then
        return 1
    fi

    return 0
}

# ------------------------------------------------------------
# 再マウント試行
# ------------------------------------------------------------
try_remount() {
    local i
    log "[WARN] ${MOUNT_POINT} is not ready. attempting remount..."

    for i in 1 2 3; do
        mount "${MOUNT_POINT}" >/dev/null 2>&1 || true
        sleep 3

        if is_mount_ok && is_write_test_ok; then
            log "[INFO] remount success (try=${i})"
            return 0
        fi

        log "[WARN] remount retry failed (try=${i})"
    done

    return 1
}

# ------------------------------------------------------------
# rsync 実行関数
#   第1引数: source
#   第2引数: dest
#   第3引数以降: rsync options
# ------------------------------------------------------------
run_rsync() {
    local src="$1"
    local dst="$2"
    shift 2

    if [ ! -e "${src}" ]; then
        log "[WARN] source not found, skip: ${src}"
        return 0
    fi

    mkdir -p "${dst}" || return 1

    log "[INFO] rsync start: ${src} -> ${dst}"
    rsync "$@" "${src}" "${dst}" >> "${LOG}" 2>&1
    local rsync_rc=$?

    # code 24 = 転送中にファイルが消えた（録音中ファイル等では実質許容）
    if [ ${rsync_rc} -eq 0 ]; then
        log "[OK] rsync success: ${src}"
        return 0
    elif [ ${rsync_rc} -eq 24 ]; then
        log "[WARN] rsync warning(code=24 vanished file): ${src}"
        return 0
    else
        log "[ERROR] rsync failed: ${src} (exit=${rsync_rc})"
        return ${rsync_rc}
    fi
}

# ------------------------------------------------------------
# メイン処理
# ------------------------------------------------------------
ensure_dirs
log "[INFO] backup started at ${TS_START}"

# 1) マウント状態確認
if ! is_mount_ok || ! is_write_test_ok; then
    if ! try_remount; then
        RESULT="NG"
        REASON="backup mount not available"
        RC=1
        log "[ERROR] ${REASON}"
        write_json || { echo "Failed to publish backup result" >&2; exit 1; }
        exit ${RC}
    fi
fi

log "[INFO] NAS mount confirmed"
log "[INFO] write test confirmed"

# 2) バックアップ先準備
mkdir -p "${DEST}" >> "${LOG}" 2>&1
if [ $? -ne 0 ]; then
    RESULT="NG"
    REASON="failed to create backup destination"
    RC=2
    log "[ERROR] ${REASON}: ${DEST}"
    write_json || { echo "Failed to publish backup result" >&2; exit 1; }
    exit ${RC}
fi

# 3) 対象限定バックアップ
run_rsync "/home/taku/scripts/" \
          "${DEST}/scripts/" \
          "${COMMON_RSYNC_OPTS[@]}"
tmp_rc=$?
if [ ${tmp_rc} -ne 0 ]; then RC=${tmp_rc}; fi

run_rsync "/home/taku/ops-git/" \
          "${DEST}/ops-git/" \
          "${COMMON_RSYNC_OPTS[@]}" \
          --copy-links \
          --exclude="systemd/"
tmp_rc=$?
if [ ${tmp_rc} -ne 0 ]; then RC=${tmp_rc}; fi

run_rsync "/home/taku/recordings/events/" \
          "${DEST}/recordings/events/" \
          "${COMMON_RSYNC_OPTS[@]}"
tmp_rc=$?
if [ ${tmp_rc} -ne 0 ]; then RC=${tmp_rc}; fi

run_rsync "/home/taku/recordings/data/" \
          "${DEST}/recordings/data/" \
          "${COMMON_RSYNC_OPTS[@]}"
tmp_rc=$?
if [ ${tmp_rc} -ne 0 ]; then RC=${tmp_rc}; fi

# 4) 結果処理
if [ ${RC} -eq 0 ]; then
    RESULT="OK"
    REASON=""
    log "[OK] rsync backup completed"
else
    RESULT="NG"
    REASON="rsync failed"
    log "[ERROR] rsync backup failed (exit=${RC})"
fi

write_json || { echo "Failed to publish backup result" >&2; exit 1; }
exit ${RC}
