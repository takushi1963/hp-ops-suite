#!/bin/bash
# ============================================================
# File    : /home/taku/projects/ops/snapshot_to_html.sh
# Version : 1.1.0-A+++
# Updated : 2026-03-24
#
# Purpose :
#   system_snapshot / backup log を HTML 化して
#   /var/www/html 配下へ配置する
#
# Notes :
#   - ログが存在しない場合でも異常終了しない
#   - glob 不一致で落ちないよう nullglob を使用
#   - HTML エスケープを行う
# ============================================================

set -euo pipefail

SRC_SNAP="/var/log/system_snapshot"
SRC_BACKUP="/var/log/backup"

DST_ROOT="/var/www/html"
DST_SNAP="${DST_ROOT}/system_snapshot"
DST_RSYNC="${DST_ROOT}/backup/logs/rsync"
DST_DD="${DST_ROOT}/backup/logs/dd"

HOST="$(hostname)"
NOW="$(date '+%Y-%m-%d %H:%M:%S')"

mkdir -p "${DST_SNAP}" "${DST_RSYNC}" "${DST_DD}"

# ------------------------------------------------------------
# ログ一覧取得
# ------------------------------------------------------------
shopt -s nullglob

SNAP_FILES=("${SRC_SNAP}"/system_snapshot_*.txt)
RSYNC_FILES=("${SRC_BACKUP}"/backup-*.log)
DD_FILES=("${SRC_BACKUP}"/dd-*.log "${SRC_BACKUP}"/backup-dd*.log)

shopt -u nullglob

LATEST_SNAP=""
LATEST_RSYNC=""
LATEST_DD=""

if ((${#SNAP_FILES[@]} > 0)); then
  LATEST_SNAP="$(printf '%s\n' "${SNAP_FILES[@]}" | sort | tail -n1)"
fi

if ((${#RSYNC_FILES[@]} > 0)); then
  LATEST_RSYNC="$(printf '%s\n' "${RSYNC_FILES[@]}" | sort | tail -n1)"
fi

if ((${#DD_FILES[@]} > 0)); then
  LATEST_DD="$(printf '%s\n' "${DD_FILES[@]}" | sort | tail -n1)"
fi

# ------------------------------------------------------------
# HTML escape helper
# ------------------------------------------------------------
html_escape() {
  sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'
}

# ------------------------------------------------------------
# index.html 生成
# ------------------------------------------------------------
OUT="${DST_SNAP}/index.html"

cat > "${OUT}" <<EOF
<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<title>System Snapshot</title>
<style>
body{font-family:monospace;background:#111;color:#eee;padding:20px}
h1,h2{color:#9cf}
a{color:#8fd}
.box{border:1px solid #333;background:#1a1a1a;padding:16px;margin:16px 0}
pre{white-space:pre-wrap;word-break:break-word;background:#000;padding:12px;border:1px solid #333}
.err{color:#f77}
ul{line-height:1.8}
</style>
</head>
<body>
<h1>System Snapshot / Backup Logs</h1>
<p>Host: ${HOST}</p>
<p>Generated: ${NOW}</p>
EOF

# ------------------------------------------------------------
# 最新 snapshot
# ------------------------------------------------------------
echo "<div class='box'><h2>📸 最新 Snapshot</h2>" >> "${OUT}"

if [[ -n "${LATEST_SNAP}" && -f "${LATEST_SNAP}" ]]; then
  echo "<p><code>${LATEST_SNAP}</code></p><pre>" >> "${OUT}"
  html_escape < "${LATEST_SNAP}" >> "${OUT}"
  echo "</pre>" >> "${OUT}"
else
  echo "<p class='err'>snapshot 不在</p>" >> "${OUT}"
fi

echo "</div>" >> "${OUT}"

# ------------------------------------------------------------
# rsync バックアップ
# ------------------------------------------------------------
echo "<div class='box'><h2>💾 rsync バックアップ</h2>" >> "${OUT}"

if [[ -n "${LATEST_RSYNC}" && -f "${LATEST_RSYNC}" ]]; then
  echo "<p>最新: <code>${LATEST_RSYNC}</code></p>" >> "${OUT}"
else
  echo "<p class='err'>rsync log 不在</p>" >> "${OUT}"
fi

echo "<ul>" >> "${OUT}"
if ((${#RSYNC_FILES[@]} > 0)); then
  printf '%s\n' "${RSYNC_FILES[@]}" | sort -r | while IFS= read -r f; do
    base="$(basename "$f")"
    cp -f "$f" "${DST_RSYNC}/${base}"
    echo "<li><a href='/backup/logs/rsync/${base}'>${base}</a></li>" >> "${OUT}"
  done
else
  echo "<li>ログなし</li>" >> "${OUT}"
fi
echo "</ul></div>" >> "${OUT}"

# ------------------------------------------------------------
# dd バックアップ
# ------------------------------------------------------------
echo "<div class='box'><h2>🧱 dd バックアップ</h2>" >> "${OUT}"

if [[ -n "${LATEST_DD}" && -f "${LATEST_DD}" ]]; then
  echo "<p>最新: <code>${LATEST_DD}</code></p>" >> "${OUT}"
else
  echo "<p class='err'>dd log 不在</p>" >> "${OUT}"
fi

echo "<ul>" >> "${OUT}"
if ((${#DD_FILES[@]} > 0)); then
  printf '%s\n' "${DD_FILES[@]}" | sort -r | while IFS= read -r f; do
    base="$(basename "$f")"
    cp -f "$f" "${DST_DD}/${base}"
    echo "<li><a href='/backup/logs/dd/${base}'>${base}</a></li>" >> "${OUT}"
  done
else
  echo "<li>ログなし</li>" >> "${OUT}"
fi
echo "</ul></div>" >> "${OUT}"

cat >> "${OUT}" <<EOF
</body>
</html>
EOF

echo "[OK] wrote: ${OUT}"
