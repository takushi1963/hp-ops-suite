#!/bin/bash
set -euo pipefail
DIR="/var/www/html/inventory"
CUR="$DIR/unused_scripts.txt"
PREV="$DIR/.unused_scripts.prev"
LOG="$DIR/diff.log"

[[ -f "$CUR" ]] || exit 0
if [[ -f "$PREV" ]]; then
  if ! diff -u "$PREV" "$CUR" > "$DIR/diff.tmp"; then
    {
      echo "=== INVENTORY DIFF $(date '+%F %T') ==="
      cat "$DIR/diff.tmp"
      echo
    } >> "$LOG"
# 通知
/home/taku/projects/ops/notify.sh \
  "Inventory changed" \
  "unused_scripts.txt に差分あり" 4

  fi
fi
cp -f "$CUR" "$PREV"
