#!/bin/bash
#
# concept_summary_to_web.sh
# Version : 1.0.0
# Updated : 2026-01-06
#
# 目的:
#   - Concept Snapshot から「設計意図サマリー」を抽出
#

set -euo pipefail

DST="/var/www/html/concept_snapshot"
OUT_HTML="$DST/summary.html"
OUT_TXT="$DST/summary.txt"

HOST="$(hostname)"
NOW="$(date '+%Y-%m-%d %H:%M:%S')"

cat > "$OUT_TXT" <<EOF
Concept Summary
Host: $HOST
Generated: $NOW

ADS-B:
- 目的: 航空機受信・可視化・MLAT
- 特徴: readsb / tar1090 / exporter / 診断

Audio:
- 目的: 航空機騒音の録音・相関
- 特徴: realtime / batch / ラベリング

Backup:
- 目的: rsync + dd による多層バックアップ
- 特徴: 状態可視化 / 自動化 / 復元前提
EOF

cat > "$OUT_HTML" <<EOF
<!DOCTYPE html><html lang="ja"><head><meta charset="UTF-8">
<title>Concept Summary</title>
<style>
body{font-family:monospace;background:#111;color:#eee;padding:20px}
h1{color:#7cf}
pre{background:#000;padding:15px;border-radius:8px}
a{color:#8df}
</style></head><body>
<h1>🧠 Concept Summary</h1>
<p>Host: $HOST<br>Generated: $NOW</p><hr>
<pre>
$(sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g' "$OUT_TXT")
</pre>
<p><a href="/concept_snapshot/">← Concept Snapshot</a></p>
</body></html>
EOF

chmod 755 "$DST"/summary.*
