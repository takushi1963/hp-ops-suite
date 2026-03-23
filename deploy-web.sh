#!/bin/bash
#
# Name    : deploy-web.sh
# Version : 1.2.0
# Updated : 2026-01-06
#
# 目的 :
#   - ops/web（Git 管理の原本）を /var/www/html に配置
#   - 表示専用 HTML のみを対象とする
#
# 方針 :
#   - 日本語メッセージのみ
#   - 余計な出力は一切表示しない
#

set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)/web/"
DST="/var/www/html/"

echo "=== Web ダッシュボード配置開始 ==="

# sudo の lecture / 余計な出力を抑止
export SUDO_ASKPASS=/bin/false
sudo -v >/dev/null 2>&1 || {
  echo "ERROR: sudo 権限が必要です"
  exit 1
}

# rsync 完全静音（--quiet + 出力破棄）
sudo rsync -a --delete \
  --quiet \
  --exclude=".git" \
  --exclude=".gitmodules" \
  "$SRC" "$DST" \
  >/dev/null 2>&1

echo "配置完了: /var/www/html/"
echo "=== 完了 ==="
