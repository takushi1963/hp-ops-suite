#!/bin/bash
#
# script_inventory_to_web.sh
# Version : 1.0.0
# Updated : 2026-01-06
#
# 目的:
#   - /usr/local/bin 配下スクリプトの棚卸し
#   - systemd / timer / cron / 実行履歴から「使用有無」を判定
#   - Web + TEXT で可視化
#
# 前提:
#   - 読み取り専用
#   - sudo 実行
#

set -euo pipefail

HOST="$(hostname)"
NOW="$(date '+%Y-%m-%d %H:%M:%S')"

SRC="/usr/local/bin"
DST="/var/www/html/inventory"

TXT="$DST/unused_scripts.txt"
HTML="$DST/unused_scripts.html"
INDEX="$DST/index.html"

mkdir -p "$DST"

# ==== 収集 ====
ALL_SCRIPTS=$(find "$SRC" -maxdepth 1 -type f -executable -printf "%f\n" | sort)

USED=""
USED+=$(systemctl list-unit-files --no-pager | awk '{print $1}')
USED+=$(systemctl list-timers --no-pager | awk '{print $1}')
USED+=$(crontab -l 2>/dev/null || true)
USED+=$(grep -R "/usr/local/bin" /etc/systemd/system 2>/dev/null || true)

# ==== 判定 ====
echo "Unused Script Inventory" > "$TXT"
echo "Host: $HOST" >> "$TXT"
echo "Generated: $NOW" >> "$TXT"
echo >> "$TXT"

echo "=== UNUSED / CANDIDATE ===" >> "$TXT"
for s in $ALL_SCRIPTS; do
  if ! echo "$USED" | grep -q "$s"; then
    echo "$SRC/$s" >> "$TXT"
  fi
done

# ==== HTML ====
{
cat <<EOF
<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<title>Script Inventory</title>
<style>
body{font-family:monospace;background:#111;color:#eee;padding:20px}
h1{color:#7cf}
pre{background:#000;padding:15px;border-radius:8px}
a{color:#8df;text-decoration:none}
</style>
</head>
<body>
<h1>🧹 Script Inventory</h1>
<p>Host: $HOST<br>Generated: $NOW</p>
<hr>
<h2>未使用候補スクリプト</h2>
<pre>
EOF

sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g' "$TXT"

cat <<EOF
</pre>
<p class="small">
※ systemd / timer / cron / service から参照されていないもの
</p>
</body></html>
EOF
} > "$HTML"

# ==== index ====
cat > "$INDEX" <<EOF
<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<title>Inventory</title>
<style>
body{font-family:monospace;background:#111;color:#eee;padding:20px}
h1{color:#7cf}
a{color:#8df;text-decoration:none;font-size:120%}
</style>
</head>
<body>
<h1>🧹 Inventory</h1>
<ul>
<li><a href="unused_scripts.html">未使用スクリプト一覧</a></li>
<li><a href="unused_scripts.txt">TEXT（ChatGPT用）</a></li>
</ul>
</body>
</html>
EOF

chmod -R 755 "$DST"
