#!/bin/bash
#
# pre_delete_snapshot.sh
# Version : 1.0.0
# Updated : 2026-01-06
#
# 目的:
#   - /usr/local/bin を削除前に丸ごと保存
#

set -euo pipefail

DST="/var/www/html/inventory/snapshots"
mkdir -p "$DST"

OUT="$DST/bin_snapshot_$(date '+%Y%m%d_%H%M%S').tar.gz"
tar czf "$OUT" /usr/local/bin

chmod 755 "$DST"
