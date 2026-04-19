#!/usr/bin/env bash
# ============================================================
# File    : /home/taku/projects/ops/deploy-web.sh
# Version : 2.0.0-A+++
# Updated : 2026-04-19
#
# Purpose :
#   OPS Web ダッシュボードの静的ファイルを /var/www/html/ に安全配置する
#
# Notes :
#   - 絶対に --delete は使わない
#   - /var/www/html/status などの生成物を消さない
#   - 静的ファイルだけを上書き配置する
#   - 配置先ディレクトリ自体は維持する
#
# ChangeLog :
#   2.0.0-A+++ : --delete を廃止し、安全配置方式へ変更
# ============================================================

set -euo pipefail

SRC="/home/taku/projects/ops/web/"
DST="/var/www/html"

echo "=== Web ダッシュボード安全配置開始 ==="

# 配置元確認
if [[ ! -d "$SRC" ]]; then
  echo "[ERROR] 配置元ディレクトリがありません: $SRC" >&2
  exit 1
fi

# 配置先確認
if [[ ! -d "$DST" ]]; then
  echo "[INFO] 配置先ディレクトリを作成します: $DST"
  sudo mkdir -p "$DST"
fi

# 静的ファイルのみ安全配置
sudo rsync -a \
  --exclude '.git/' \
  --exclude '*.bak' \
  --exclude '*.tmp' \
  --exclude 'status/' \
  --exclude 'reports/' \
  --exclude 'concept_snapshot/' \
  --exclude 'system_snapshot/' \
  --exclude 'backup-logs/' \
  --exclude 'backup/' \
  --exclude 'audio-events/' \
  --exclude 'audio-files/' \
  "$SRC" "$DST/"

# 権限を軽く整える
sudo find "$DST" -maxdepth 1 -type f -name '*.html' -exec chmod 644 {} \;
sudo find "$DST" -maxdepth 1 -type f -name '*.css'  -exec chmod 644 {} \;
sudo find "$DST" -maxdepth 1 -type f -name '*.js'   -exec chmod 644 {} \;

echo "配置完了: $DST"
echo "=== 完了 ==="
