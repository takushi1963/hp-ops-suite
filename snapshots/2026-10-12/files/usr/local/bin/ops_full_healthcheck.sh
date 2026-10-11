#!/bin/bash
# ROLE: OPS
#!/bin/bash
# ============================================================
# File    : ops_full_healthcheck.sh
# Version : 1.0.0
# Updated : 2026-01-30
#
# Purpose :
#   OPS Full Health Check
#   - Hardware / OS facts
#   - Service status
#   - ADS-B / Audio / Backup checks
#   - READ-ONLY, fact based
#
# Policy :
#   - No auto recovery
#   - No state change
#   - Use existing check scripts
# ============================================================

set -u
health_failed=0

HOST="$(hostname)"
NOW="$(date '+%Y-%m-%d %H:%M:%S')"

echo "===== OPS FULL HEALTH CHECK ====="
echo "TIME        : $NOW"
echo "HOST        : $HOST"

### ===== OS / HW =====
OS="$(. /etc/os-release && echo "$PRETTY_NAME")"
KERNEL="$(uname -r)"
UPTIME="$(uptime -p)"
LOAD="$(uptime | awk -F'load average:' '{print $2}')"

echo "OS          : $OS"
echo "KERNEL      : $KERNEL"
echo "UPTIME      : $UPTIME"
echo "LOAD        : $LOAD"

### ===== Disk =====
df -h / | awk 'NR==2{print "DISK /      : "$5" used"}'

if mountpoint -q /mnt/backup; then
  df -h /mnt/backup | awk 'NR==2{print "DISK BACKUP : "$5" used"}'
else
  echo "DISK BACKUP : NOT MOUNTED"
fi

### ===== ADS-B =====
echo
echo "[ADS-B]"

for CMD in \
  dump1090_healthcheck.sh \
  adsb_location_check.sh \
  aircraft_quality_check.sh
do
  if [ -x "/usr/local/bin/$CMD" ]; then
    echo "--- $CMD ---"
    /usr/local/bin/$CMD || health_failed=1
  else
    echo "$CMD : NOT FOUND"
  fi
done

### ===== AUDIO =====
echo
echo "[AUDIO]"
if [ -x /usr/local/bin/audio_ops_check.sh ]; then
  /usr/local/bin/audio_ops_check.sh || health_failed=1
else
  echo "audio_ops_check.sh : NOT FOUND"
fi

### ===== BACKUP =====
echo
echo "[BACKUP]"
for CMD in backup_health_check.sh
do
  if [ -x "/usr/local/bin/$CMD" ]; then
    echo "--- $CMD ---"
    /usr/local/bin/$CMD || health_failed=1
  else
    echo "$CMD : NOT FOUND"
  fi
done

echo
echo "===== END ====="

exit "$health_failed"
