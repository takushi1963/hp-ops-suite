# ROLE: OPS
#!/bin/bash
# ============================================================
# File    : /usr/local/bin/ops-audio-ring.sh
# Version : 1.1.0
# Updated : 2026-04-01
#
# Purpose :
#   60秒単位でWAVをリング録音し、wav_raw に保存する
#
# Notes :
#   - ディスク節約のため 16kHz / mono / 16bit に統一
#   - hw: ではなく plughw: を使い、ALSA変換を許可する
#   - 出力は .part に書いてから完成後に .wav へ rename する
#   - 保存先は /home/taku/recordings/wav_raw
# ============================================================

set -u

REC_DIR="/home/taku/recordings/wav_raw"
DEVICE="plughw:PCH,0"
FORMAT="S16_LE"
RATE="16000"
CH="1"
CHUNK_SEC="60"
SLEEP_ON_ERROR="5"

mkdir -p "$REC_DIR"

log() {
  echo "[$(date '+%F %T')] $*"
}

while true; do
  TS_UTC="$(date -u +'%Y-%m-%dT%H-%M-%SZ')"
  OUT_WAV="${REC_DIR}/raw_${TS_UTC}.wav"
  OUT_TMP="${OUT_WAV}.part"

  rm -f "$OUT_TMP"

  log "START record : device=${DEVICE} rate=${RATE} ch=${CH} out=${OUT_WAV}"

  if arecord -D "$DEVICE" -f "$FORMAT" -r "$RATE" -c "$CH" -d "$CHUNK_SEC" "$OUT_TMP"; then
    if [ -f "$OUT_TMP" ]; then
      mv "$OUT_TMP" "$OUT_WAV"
      log "DONE  record : ${OUT_WAV}"
    else
      log "WARN  temp file not found after recording : ${OUT_TMP}"
    fi
  else
    log "ERROR arecord failed, retry after ${SLEEP_ON_ERROR}s"
    rm -f "$OUT_TMP"
    sleep "$SLEEP_ON_ERROR"
  fi
done
