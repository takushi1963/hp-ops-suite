#!/bin/bash
#
# snapshot_to_html.sh
# Version : 1.2.0
# Updated : 2026-01-06
#
# 目的:
#   - system_snapshot / rsync / dd のログを横断可視化
#   - 「1ページで現状判断できる」Webダッシュボード生成
#
# 前提:
#   - 読み取り専用（ログ非破壊）
#   - sudo 実行
#

set -euo pipefail

# ==== 設定 ====
SRC_SNAP="/var/log/system_snapshot"
SRC_BACKUP="/var/log/backup"

DST_ROOT="/var/www/html"
DST_SNAP="${DST_ROOT}/system_snapshot"
DST_RSYNC="${DST_ROOT}/backup/logs/rsync"
DST_DD="${DST_ROOT}/backup/logs/dd"

HOST="$(hostname)"
NOW="$(date '+%Y-%m-%d %H:%M:%S')"

mkdir -p "$DST_SNAP" "$DST_RSYNC" "$DST_DD"

LATEST_SNAP="$(ls -1 ${SRC_SNAP}/system_snapshot_*.txt 2>/dev/null | sort | tail -n1 || true)"
LATEST_RSYNC="$(ls -1 ${SRC_BACKUP}/backup-*.log 2>/dev/null | sort | tail -n1 || true)"
LATEST_DD="$(ls -1 ${SRC_BACKUP}/{dd-*,backup-dd*}.log 2>/dev/null | sort | tail -n1 || true)"

OUT="${DST_SNAP}/index.html"

# ==== HTML ヘッダ ====
cat > "$OUT" <<EOF
<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<title>System Snapshot | ${HOST}</title>
<style>
body{font-family:monospace;background:#111;color:#eee;padding:20px}
h1{color:#7cf}
h2{color:#9df;margin-top:30px}
pre{background:#000;padding:15px;border-radius:8px;overflow:auto}
.box{background:#181818;padding:15px;border-radius:8px;margin-bottom:20px}
a{color:#8df;text-decoration:none}
a:hover{text-decoration:underline}
.ok{color:#7f7}
.err{color:#f77}
.small{opacity:.8;font-size:90%}
</style>
</head>
<body>

<h1>🧾 System Snapshot</h1>
<p class="small">
Host: ${HOST}<br>
Generated: ${NOW}
</p>
<hr>
EOF

# ==== 最新 Snapshot ====
echo "<div class='box'><h2>📸 最新 Snapshot</h2>" >> "$OUT"
if [[ -f "$LATEST_SNAP" ]]; then
  echo "<p><code>${LATEST_SNAP}</code></p><pre>" >> "$OUT"
  sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g' "$LATEST_SNAP" >> "$OUT"
  echo "</pre>" >> "$OUT"
else
  echo "<p class='err'>snapshot 不在</p>" >> "$OUT"
fi
echo "</div>" >> "$OUT"

# ==== rsync ====
echo "<div class='box'><h2>💾 rsync バックアップ</h2>" >> "$OUT"
if [[ -f "$LATEST_RSYNC" ]]; then
  RC="$(grep -Eo 'exit code[: ]+[0-9]+' "$LATEST_RSYNC" | tail -n1 | awk '{print $NF}' || true)"
  [[ "$RC" == "0" || -z "$RC" ]] && STAT="<span class='ok'>OK</span>" || STAT="<span class='err'>ERROR rc=$RC</span>"
  B="$(basename "$LATEST_RSYNC")"
  echo "<p>最新: <a href='/backup/logs/rsync/$B'>$B</a></p>" >> "$OUT"
  echo "<p>状態: $STAT</p>" >> "$OUT"
else
  echo "<p class='err'>rsync log 不在</p>" >> "$OUT"
fi
echo "<ul>" >> "$OUT"
ls -1 ${SRC_BACKUP}/backup-*.log 2>/dev/null | sort -r | while read f; do
  b="$(basename "$f")"
  echo "<li><a href='/backup/logs/rsync/$b'>$b</a></li>" >> "$OUT"
done
echo "</ul></div>" >> "$OUT"

# ==== dd ====
echo "<div class='box'><h2>📀 dd バックアップ</h2>" >> "$OUT"
if [[ -f "$LATEST_DD" ]]; then
  RC="$(grep -Ei 'error|failed' "$LATEST_DD" >/dev/null && echo 1 || echo 0)"
  [[ "$RC" == "0" ]] && STAT="<span class='ok'>OK</span>" || STAT="<span class='err'>ERROR</span>"
  B="$(basename "$LATEST_DD")"
  echo "<p>最新: <a href='/backup/logs/dd/$B'>$B</a></p>" >> "$OUT"
  echo "<p>状態: $STAT</p>" >> "$OUT"
else
  echo "<p class='err'>dd log 不在</p>" >> "$OUT"
fi
echo "<ul>" >> "$OUT"
ls -1 ${SRC_BACKUP}/{dd-*,backup-dd*}.log 2>/dev/null | sort -r | while read f; do
  b="$(basename "$f")"
  echo "<li><a href='/backup/logs/dd/$b'>$b</a></li>" >> "$OUT"
done
echo "</ul></div>" >> "$OUT"

echo "</body></html>" >> "$OUT"

# ==== 生ログコピー ====
cp -a ${SRC_SNAP}/system_snapshot_*.txt "$DST_SNAP/" 2>/dev/null || true
cp -a ${SRC_BACKUP}/backup-*.log "$DST_RSYNC/" 2>/dev/null || true
cp -a ${SRC_BACKUP}/{dd-*,backup-dd*}.log "$DST_DD/" 2>/dev/null || true

chmod -R 755 "$DST_ROOT/system_snapshot" "$DST_ROOT/backup"
