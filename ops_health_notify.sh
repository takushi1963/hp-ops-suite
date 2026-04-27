#!/bin/bash
# ops_health_notify.sh
set -euo pipefail

NOTIFY="/home/taku/projects/ops/notify.sh"

# systemd failed
FAILED="$(systemctl --failed --no-pager | sed 1,3d | wc -l)"
if [[ "$FAILED" -gt 0 ]]; then
"$NOTIFY" "Service failed" "systemd failed units=${FAILED}" 5 || true
fi

# rsync latest
RSYNC_LOG="$(ls -1 /var/log/backup/backup-*.log 2>/dev/null | sort | tail -n1 || true)"
if [[ -f "$RSYNC_LOG" ]] && grep -qiE 'error|failed|exit code: [^0]' "$RSYNC_LOG"; then
"$NOTIFY" "Service failed" "systemd failed units=${FAILED}" 5 || true
fi

# dd latest
DD_LOG="$(ls -1 /var/log/backup/{dd-*,backup-dd*}.log 2>/dev/null | sort | tail -n1 || true)"
if [[ -f "$DD_LOG" ]] && grep -qiE 'error|failed' "$DD_LOG"; then
"$NOTIFY" "Service failed" "systemd failed units=${FAILED}" 5 || true
fi
