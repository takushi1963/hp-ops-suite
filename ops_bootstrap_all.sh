#!/bin/bash
#
# ops_bootstrap_all.sh
# Version : 1.0.0
# Updated : 2026-01-06
#
# 目的:
#   - OPS 環境の全仕組みを一括構築・再生成
#   - Concept / System / OPS / Inventory を自己記述型に完成させる
#
# 実行:
#   sudo ~/projects/ops/ops_bootstrap_all.sh
#

set -euo pipefail

REAL_USER="$(logname)"
OPS_HOME="/home/${REAL_USER}/projects/ops"
WEB="/var/www/html"

echo "=== OPS BOOTSTRAP START ==="

# 1. Concept Snapshot
echo "[1/8] Concept Snapshot"
sudo "$OPS_HOME/concept_snapshot_to_web.sh"

# 2. System Snapshot
echo "[2/8] System Snapshot"
sudo "$OPS_HOME/snapshot_to_html.sh"

# 3. Inventory (unused)
echo "[3/8] Inventory (unused)"
sudo "$OPS_HOME/script_inventory_to_web.sh"

# 4. Inventory classify
echo "[4/8] Inventory classify"
sudo "$OPS_HOME/script_inventory_classify.sh"

# 5. DELETE_CANDIDATE 無効化
echo "[5/8] Disable DELETE_CANDIDATE"
awk '/^=== DELETE_CANDIDATE ===/{f=1;next}/^===/{f=0}f{print}' \
"$WEB/inventory/classified_scripts.txt" 2>/dev/null | \
while read -r p; do
  [[ -x "$p" ]] && chmod -x "$p" && echo "disabled: $p"
done || true

# 6. 役割タグ付与
echo "[6/8] Tag scripts by role"
sudo "$OPS_HOME/tag_scripts_by_role.sh"

# 7. 削除前スナップショット
echo "[7/8] Pre-delete snapshot"
sudo "$OPS_HOME/pre_delete_snapshot.sh"

# 8. 相互リンク確認（存在前提、未作成ならスキップ）
echo "[8/8] Link check"
for d in system_snapshot concept_snapshot ops inventory; do
  [[ -d "$WEB/$d" ]] && echo "OK: /$d/"
done

echo "=== OPS BOOTSTRAP COMPLETE ==="
