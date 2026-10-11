#!/bin/bash
# OPS repair: job-duration shared lock, partial output, explicit success record.
set -euo pipefail
exec 200>/run/ops-backup.lock
flock -n 200 || { echo 'Another backup is running' >&2; exit 75; }
mountpoint -q /mnt/backup || { echo 'Backup mount is unavailable' >&2; exit 1; }
SRC=/dev/sda
[[ -b "$SRC" ]] || { echo 'Backup source is not a block device' >&2; exit 1; }
OUT_DIR=/mnt/backup/dd
OUT_FILE="$OUT_DIR/$(hostname)_$(date +%F).img.gz"
mkdir -p "$OUT_DIR"
[[ ! -e "$OUT_FILE" ]] || { echo 'Backup image already exists; refusing overwrite' >&2; exit 1; }
PARTIAL="${OUT_FILE}.partial.$$"
STARTED=$(date -Is)
finish() {
    local code=$? result=NG reason="DD job failed; partial output retained"
    trap - EXIT
    if [[ "$code" -eq 0 ]]; then result=OK; reason='gzip pipeline completed; restore not tested'; fi
    if ! /usr/bin/python3 /usr/local/lib/ops-dashboard-repair/collector.py write-backup dd \
        "$STARTED" "$(date -Is)" "$(hostname)" "$OUT_FILE" "$result" "$reason" "$code"; then
        echo 'Failed to publish DD completion status' >&2
        [[ "$code" -ne 0 ]] || code=1
    fi
    exit "$code"
}
trap finish EXIT
printf '[INFO] DD started: %s\n' "$OUT_FILE"
dd if="$SRC" bs=64M status=progress | gzip > "$PARTIAL"
mv -- "$PARTIAL" "$OUT_FILE"
printf '[OK] DD pipeline completed: %s\n' "$OUT_FILE"
