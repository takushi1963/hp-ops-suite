#!/bin/bash
#
# Name    : backup-status.sh
# Version : 1.0.0
# Updated : 2026-01-06
#
# Purpose :
#   - バックアップ全体の「今の状態」を一発表示する
#   - dd / rsync / mount / timer の健全性を確認
#
# Usage :
#   - 手動実行: ./backup-status.sh
#
# Systemd :
#   - backup-dd.timer
#   - backup-rsync.timer
#
# Notes :
#   - 破壊的操作は一切行わない（read-only）
#   - ChatGPT への貼り付け前提の出力構成
#

echo "========================================"
echo " Backup System Status"
echo " Host      : $(hostname)"
echo " Timestamp : $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================"
echo

# --- Mount check ---
echo "[Mount Status]"
if mount | grep -q "/mnt/backup"; then
    echo "  /mnt/backup : MOUNTED"
    df -h /mnt/backup | sed '1d' | awk '{printf "    Size:%s Used:%s Avail:%s Use:%s\n",$2,$3,$4,$5}'
else
    echo "  /mnt/backup : NOT MOUNTED"
fi
echo

# --- Latest backup files ---
echo "[Latest Backup Files]"
BACKUP_DIR="/mnt/backup"
if [[ -d "$BACKUP_DIR" ]]; then
    find "$BACKUP_DIR" -type f \( -name "*.img*" -o -name "*.tar*" \) \
        -printf "  %TY-%Tm-%Td %TH:%TM  %s bytes  %p\n" 2>/dev/null \
        | sort -r | head -5
else
    echo "  Backup directory not accessible"
fi
echo

# --- Backup logs ---
echo "[Backup Logs]"
LOG_DIR="/var/log/backup"
if [[ -d "$LOG_DIR" ]]; then
    ls -lt "$LOG_DIR" | head -5
else
    echo "  No backup log directory"
fi
echo

# --- systemd timers ---
echo "[Systemd Timers]"
systemctl list-timers --no-pager | grep -E "backup|dd|rsync" || echo "  No backup timers found"
echo

# --- disk health ---
echo "[Disk Usage]"
df -h / | sed '1d' | awk '{printf "  Root FS : Size:%s Used:%s Avail:%s Use:%s\n",$2,$3,$4,$5}'
echo

echo "Status check completed."
