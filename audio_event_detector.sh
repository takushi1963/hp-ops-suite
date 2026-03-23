#!/bin/bash
#
# audio_event_detector.sh
# Version : 1.2.0
# Updated : 2026-01-06
#
# Purpose:
#   録音ファイルから「飛行機音が発生した日時」を
#   ADS-B 非依存で検出し、
#   - 絶対時刻
#   - 再生開始からの相対時間
#   を同時に記録・Web公開する
#

set -euo pipefail
export LC_ALL=C

CONF="/etc/ops/audio_event.conf"
[[ -f "$CONF" ]] || { echo "ERROR: $CONF not found"; exit 1; }
# shellcheck disable=SC1090
source "$CONF"

command -v ffmpeg  >/dev/null || { echo "ERROR: ffmpeg not found"; exit 1; }
command -v ffprobe >/dev/null || { echo "ERROR: ffprobe not found"; exit 1; }

mkdir -p "$WEB_EVENT_DIR" "$WEB_AUDIO_DIR" "$STATE_DIR"

STATE_FILE="$STATE_DIR/processed_files.txt"
EVENT_CSV="$WEB_EVENT_DIR/events.csv"
EVENT_JSON="$WEB_EVENT_DIR/events.json"
EVENT_HTML="$WEB_EVENT_DIR/index.html"

touch "$STATE_FILE"
[[ -f "$EVENT_CSV" ]] || \
echo "event_start,event_end,offset_start,offset_end,duration_sec,offset_hms,file" > "$EVENT_CSV"

log(){ echo "[$(date '+%F %T')] $*"; }

# ---- utility -------------------------------------------------

file_start_epoch() {
  local b
  b="$(basename "$1")"
  if [[ "$b" =~ $FILENAME_TS_REGEX ]]; then
    date -d "${BASH_REMATCH[1]//_/ }" +%s
  else
    stat -c %Y "$1"
  fi
}

duration_sec() {
  local d
  d="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$1" || true)"
  [[ "$d" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { echo 0; return; }
  printf "%.0f\n" "$d"
}

sec_to_hms() {
  local s="$1"
  printf "%02d:%02d" $((s/60)) $((s%60))
}

publish_audio() {
  local b
  b="$(basename "$1")"
  [[ -e "$WEB_AUDIO_DIR/$b" ]] || ln -s "$1" "$WEB_AUDIO_DIR/$b"
}

allowed_ext() {
  local e="${1##*.}"
  case " $AUDIO_EXTS " in
    *" $e "*) return 0 ;;
    *) return 1 ;;
  esac
}

append_event() {
  local start_epoch="$1" file="$2" os="$3" oe="$4"

  [[ "$oe" -gt "$os" ]] || return
  local dur=$((oe-os))
  [[ "$dur" -ge "$MIN_EVENT_SEC" ]] || return

  local ev_start ev_end rel
  ev_start="$(date -d "@$((start_epoch+os))" '+%Y-%m-%d %H:%M:%S')"
  ev_end="$(date -d "@$((start_epoch+oe))" '+%Y-%m-%d %H:%M:%S')"
  rel="$(sec_to_hms "$os")"

  echo "$ev_start,$ev_end,$os,$oe,$dur,$rel,$file" >> "$EVENT_CSV"
  log "event $ev_start +$rel ($dur s) $file"
}

# ---- render --------------------------------------------------

render_json() {
  {
    echo "["
    tail -n +2 "$EVENT_CSV" | awk -F, '
      BEGIN{f=1}
      {
        gsub(/"/,"\\\"",$7)
        j=sprintf("{\"event_start\":\"%s\",\"event_end\":\"%s\",\"offset_start\":%s,\"offset_end\":%s,\"duration_sec\":%s,\"offset_hms\":\"%s\",\"file\":\"%s\"}",
                  $1,$2,$3,$4,$5,$6,$7)
        if(f){print "  "j;f=0}else{print "  ,"j}
      }'
    echo "]"
  } > "$EVENT_JSON"
}

render_html() {
  {
    echo "<!DOCTYPE html><html><head><meta charset='UTF-8'>"
    echo "<title>Audio Events</title>"
    echo "<style>
      body{font-family:sans-serif;background:#111;color:#eee;padding:20px}
      h1{color:#7cf}
      table{border-collapse:collapse;width:100%;max-width:1200px}
      th,td{border-bottom:1px solid #333;padding:8px}
      th{background:#222}
      a{color:#8df;text-decoration:none}
      code{background:#222;padding:2px 4px;border-radius:4px}
      .small{opacity:.8;font-size:90%}
    </style></head><body>"
    echo "<h1>🎧 Audio Events（ADS-B非依存）</h1>"
    echo "<p class='small'>CSV: <a href='events.csv'>events.csv</a> / JSON: <a href='events.json'>events.json</a></p>"
    echo "<table>"
    echo "<tr><th>絶対時刻</th><th>相対</th><th>再生</th><th>DL</th><th>ファイル</th></tr>"
    tail -n +2 "$EVENT_CSV" | while IFS=, read -r st en os oe dur rel file; do
      echo "<tr>"
      echo "<td><b>$st</b><div class='small'>〜 $en</div></td>"
      echo "<td><code>+$rel</code></td>"
      echo "<td><audio controls preload='none' src='/audio-files/$file#t=$os,$oe'></audio></td>"
      echo "<td><a href='/audio-files/$file' download>download</a></td>"
      echo "<td><code>$file</code><div class='small'>offset $os-$oe</div></td>"
      echo "</tr>"
    done
    echo "</table></body></html>"
  } > "$EVENT_HTML"
}

# ---- main ----------------------------------------------------

log "start"

for f in "$AUDIO_DIR"/*; do
  [[ -f "$f" ]] || continue
  allowed_ext "$f" || continue
  grep -Fxq "$f" "$STATE_FILE" && continue

  publish_audio "$f"

  total="$(duration_sec "$f")"
  [[ "$total" -gt 0 ]] || { echo "$f" >> "$STATE_FILE"; continue; }

  start_epoch="$(file_start_epoch "$f")"
  base="$(basename "$f")"

  sil_tmp="$(mktemp)"
  ffmpeg -nostats -hide_banner -i "$f" \
    -af "silencedetect=noise=$SILENCE_NOISE_DB:d=$SILENCE_MIN_SEC" \
    -f null - 2>&1 | \
    awk '
      /silence_start:/ {for(i=1;i<=NF;i++)if($i=="silence_start:")print "S",int($(i+1)+0.5)}
      /silence_end:/   {for(i=1;i<=NF;i++)if($i=="silence_end:")  print "E",int($(i+1)+0.5)}
    ' > "$sil_tmp" || true

  prev=0; have=0; cur=""
  while read -r t v; do
    [[ "$t" == "S" ]] && cur="$v"
    if [[ "$t" == "E" && -n "$cur" ]]; then
      os=$((prev-PAD_SEC)); [[ "$os" -lt 0 ]] && os=0
      oe=$((cur+PAD_SEC)); [[ "$oe" -gt "$total" ]] && oe="$total"
      append_event "$start_epoch" "$base" "$os" "$oe"
      prev="$v"; have=1; cur=""
    fi
  done < "$sil_tmp"

  rm -f "$sil_tmp"

  os=$((prev-PAD_SEC)); [[ "$os" -lt 0 ]] && os=0
  oe="$total"
  append_event "$start_epoch" "$base" "$os" "$oe"

  [[ "$have" -eq 0 ]] && append_event "$start_epoch" "$base" 0 "$total"

  echo "$f" >> "$STATE_FILE"
done

render_json
render_html
log "done"
