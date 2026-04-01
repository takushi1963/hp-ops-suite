#!/bin/bash
#
# concept_snapshot_to_web.sh
# Version : 1.1.0
# Updated : 2026-01-06
#
# 目的:
#   - adsb / audio / backup の「仕組み・思想・構成」を可視化
#   - snapshot.txt と同格の「構成スナップショット」を生成
#
# 前提:
#   - 設計資料は通常ユーザー(taku)の HOME 配下
#   - Web 出力のみ root 権限が必要
#


set -euo pipefail

REAL_USER="$(logname)"
HOST="$(hostname)"
NOW="$(date '+%Y-%m-%d %H:%M:%S')"

SRC_BASE="/home/${REAL_USER}/projects"
DST="/var/www/html/concept_snapshot"

#mkdir -p "$DST"
mkdir -p "${DST}"

TXT_OUT="$DST/concept_snapshot.txt"
HTML_INDEX="$DST/index.html"

escape_html() {
  sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g'
}

write_section () {
  local NAME="$1"
  local DIR="$2"

  echo "========================================" >> "$TXT_OUT"
  echo "[$NAME]" >> "$TXT_OUT"
  echo "Path : $DIR" >> "$TXT_OUT"
  echo "========================================" >> "$TXT_OUT"
  echo >> "$TXT_OUT"

  [[ -f "$DIR/README.md" ]] && {
    echo "--- README.md ---" >> "$TXT_OUT"
    cat "$DIR/README.md" >> "$TXT_OUT"
    echo >> "$TXT_OUT"
  }

  [[ -f "$DIR/DESIGN.md" ]] && {
    echo "--- DESIGN.md ---" >> "$TXT_OUT"
    cat "$DIR/DESIGN.md" >> "$TXT_OUT"
    echo >> "$TXT_OUT"
  }

  echo "--- Scripts ---" >> "$TXT_OUT"
  find "$DIR" -maxdepth 2 -type f -executable \
    -not -name "*.md" \
    -printf "%p\n" >> "$TXT_OUT"
  echo >> "$TXT_OUT"
}

write_html_page () {
  local NAME="$1"
  local DIR="$2"
  local OUT="$DST/${NAME}.html"

  {
    cat <<EOF
<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<title>${NAME} Concept Snapshot</title>
<style>
body{font-family:monospace;background:#111;color:#eee;padding:20px}
h1{color:#7cf}
h2{color:#9df;margin-top:30px}
pre{background:#000;padding:15px;border-radius:8px;overflow:auto}
a{color:#8df;text-decoration:none}
</style>
</head>
<body>
<h1>${NAME} Concept Snapshot</h1>
<p>Host: ${HOST}<br>Generated: ${NOW}</p>
<hr>
EOF

    [[ -f "$DIR/README.md" ]] && {
      echo "<h2>README.md</h2><pre>"
      cat "$DIR/README.md" | escape_html
      echo "</pre>"
    }

    [[ -f "$DIR/DESIGN.md" ]] && {
      echo "<h2>DESIGN.md</h2><pre>"
      cat "$DIR/DESIGN.md" | escape_html
      echo "</pre>"
    }

    echo "<h2>Scripts</h2><pre>"
    find "$DIR" -maxdepth 2 -type f -executable \
      -not -name "*.md" \
      -printf "%p\n" | escape_html
    echo "</pre>"

    echo "</body></html>"
  } > "$OUT"
}

# ==== 初期化 ====
echo "Concept Snapshot" > "$TXT_OUT"
echo "Host: $HOST" >> "$TXT_OUT"
echo "Generated: $NOW" >> "$TXT_OUT"
echo >> "$TXT_OUT"

# ==== 対象 ====
write_section "ADS-B"  "$SRC_BASE/ops-adsb"
write_section "AUDIO"  "$SRC_BASE/ops-audio"
write_section "BACKUP" "$SRC_BASE/ops-backup"

write_html_page "adsb"   "$SRC_BASE/ops-adsb"
write_html_page "audio"  "$SRC_BASE/ops-audio"
write_html_page "backup" "$SRC_BASE/ops-backup"

# ==== index ====
cat > "$HTML_INDEX" <<EOF
<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<title>Concept Snapshot</title>
<style>
body{font-family:monospace;background:#111;color:#eee;padding:20px}
h1{color:#7cf}
a{color:#8df;text-decoration:none;font-size:120%}
</style>
</head>
<body>
<h1>📘 Concept Snapshot</h1>
<ul>
<li><a href="adsb.html">ADS-B 構成・思想</a></li>
<li><a href="audio.html">Audio 構成・思想</a></li>
<li><a href="backup.html">Backup 構成・思想</a></li>
<li><a href="concept_snapshot.txt">全文（TEXT / ChatGPT用）</a></li>
</ul>
</body>
</html>
EOF

chmod -R 755 "$DST"
