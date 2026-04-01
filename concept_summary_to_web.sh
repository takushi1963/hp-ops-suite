#!/bin/bash
# ============================================================
# File    : /home/taku/projects/ops/concept_summary_to_web.sh
# Version : 1.1.0-A+++
# Updated : 2026-03-25
#
# Purpose :
#   Concept Summary を /var/www/html/concept_snapshot 配下へ出力する
#
# Notes :
#   - 出力先ディレクトリが無い場合でも mkdir -p で自動作成
#   - systemd / root 実行でも安定動作する
#   - HTML / TXT の両方を生成する
# ============================================================

set -euo pipefail

DST="/var/www/html/concept_snapshot"
OUT_HTML="${DST}/summary.html"
OUT_TXT="${DST}/summary.txt"

HOST="$(hostname)"
NOW="$(date '+%Y-%m-%d %H:%M:%S')"

# ------------------------------------------------------------
# 出力先を必ず作る
# ------------------------------------------------------------
mkdir -p "${DST}"

# ------------------------------------------------------------
# テキスト出力
# ------------------------------------------------------------
cat > "${OUT_TXT}" <<EOF
Concept Summary
Host: ${HOST}
Generated: ${NOW}

This page summarizes the current concept layout.
- ADS-B
- AUDIO
- BACKUP
EOF

# ------------------------------------------------------------
# HTML出力
# ------------------------------------------------------------
cat > "${OUT_HTML}" <<EOF
<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<title>Concept Summary</title>
<style>
body{font-family:monospace;background:#111;color:#eee;padding:20px}
h1{color:#9cf}
pre{background:#000;border:1px solid #333;padding:12px;white-space:pre-wrap}
</style>
</head>
<body>
<h1>Concept Summary</h1>
<p>Host: ${HOST}</p>
<p>Generated: ${NOW}</p>
<pre>
EOF

sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g' "${OUT_TXT}" >> "${OUT_HTML}"

cat >> "${OUT_HTML}" <<EOF
</pre>
</body>
</html>
EOF

chmod 755 "${OUT_HTML}" "${OUT_TXT}"

echo "[OK] wrote: ${OUT_TXT}"
echo "[OK] wrote: ${OUT_HTML}"
