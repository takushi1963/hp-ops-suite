#!/bin/bash
#
# script_inventory_classify.sh
# Version : 1.0.0
# Updated : 2026-01-06
#
# 目的:
#   - inventory/unused_scripts.txt を分類
#   - KEEP / MERGE / DELETE_CANDIDATE / UNKNOWN
#

set -euo pipefail

SRC="/var/www/html/inventory/unused_scripts.txt"
DST="/var/www/html/inventory"
TXT="$DST/classified_scripts.txt"
HTML="$DST/classified_scripts.html"

[[ -f "$SRC" ]] || exit 0

echo "Script Classification" > "$TXT"
echo "Generated: $(date '+%Y-%m-%d %H:%M:%S')" >> "$TXT"
echo >> "$TXT"

for tag in KEEP MERGE DELETE_CANDIDATE UNKNOWN; do
  echo "=== $tag ===" >> "$TXT"
  grep -i "$tag" "$SRC" 2>/dev/null || true
  echo >> "$TXT"
done

# HTML
{
cat <<EOF
<!DOCTYPE html><html lang="ja"><head><meta charset="UTF-8">
<title>Script Classification</title>
<style>
body{font-family:monospace;background:#111;color:#eee;padding:20px}
h1{color:#7cf} h2{color:#9df}
pre{background:#000;padding:15px;border-radius:8px}
a{color:#8df}
</style></head><body>
<h1>🗂 Script Classification</h1>
<p>Generated: $(date '+%Y-%m-%d %H:%M:%S')</p><hr>
<pre>
EOF
sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g' "$TXT"
cat <<EOF
</pre></body></html>
EOF
} > "$HTML"

chmod -R 755 "$DST"
