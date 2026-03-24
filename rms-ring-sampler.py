#!/usr/bin/env python3
# ============================================================
# File    : rms-ring-sampler.py
# Version : 1.2.0-A+++ (Threshold Integrated)
# Updated : 2026-02-17
#
# Purpose :
#   USBマイク(plughw)から RMS(dB) を周期取得し、
#   ① 10分リング保存（rms_ring）
#   ② 全履歴保存（rms_history）
#   ③ 固定閾値検出（AUTOイベント登録）
#
# Threshold Logic :
#   -40 dB を 3回連続超過でイベント発生
#   ラッチ機構あり（音が下がるまで再発火しない）
#
# Notes :
#   - 入力: plughw:2,0
#   - WAV保存なし
#   - 自動爆音候補検出のみ
# ============================================================

import subprocess
import sqlite3
from datetime import datetime, timezone
import time

DB = "/var/lib/ops-audio/boom_rms.db"
ALSA_DEVICE = "plughw:2,0"
INTERVAL_SEC = 2

# ---- Threshold Settings ----
THRESHOLD_DB = -40
CONSECUTIVE_REQUIRED = 3

consecutive = 0
event_latched = False


# ------------------------------------------------------------
# RMS取得
# ------------------------------------------------------------
def get_rms_db():
    cmd = [
        "ffmpeg",
        "-hide_banner",
        "-loglevel", "info",
        "-f", "alsa",
        "-i", ALSA_DEVICE,
        "-t", "1",
        "-af", "astats=metadata=1:reset=1",
        "-f", "null",
        "-"
    ]

    p = subprocess.Popen(
        cmd,
        stderr=subprocess.PIPE,
        stdout=subprocess.DEVNULL,
        text=True
    )

    for line in p.stderr:
        if "RMS level dB" in line:
            try:
                return float(line.strip().split()[-1])
            except:
                return None
    return None


# ------------------------------------------------------------
# DB保存（リング + 履歴）
# ------------------------------------------------------------
def insert_rms(rms_db):
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    with sqlite3.connect(DB) as con:

        # ① リング保存
        con.execute(
            "INSERT INTO rms_ring (ts_utc, rms_db, context) VALUES (?, ?, 'BASELINE')",
            (ts, rms_db)
        )

        # ② 履歴保存
        con.execute(
            "INSERT INTO rms_history (ts_utc, rms_db) VALUES (?, ?)",
            (ts, rms_db)
        )

        # ③ 10分より古いリング削除
        con.execute("""
            DELETE FROM rms_ring
            WHERE datetime(substr(ts_utc,1,19))
                  < datetime('now','-10 minutes')
        """)

        con.commit()


# ------------------------------------------------------------
# AUTOイベント登録
# ------------------------------------------------------------
def insert_event():
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    with sqlite3.connect(DB) as con:
        con.execute(
            "INSERT INTO events (wav_path, event_ts) VALUES (?, ?)",
            ("AUTO_THRESHOLD", ts)
        )
        con.commit()


# ------------------------------------------------------------
# メインループ
# ------------------------------------------------------------
def main():
    global consecutive
    global event_latched

    while True:
        rms = get_rms_db()

        if rms is not None:

            insert_rms(rms)

            # ---- Threshold判定 ----
            if rms > THRESHOLD_DB:
                consecutive += 1
            else:
                consecutive = 0
                event_latched = False

            if consecutive >= CONSECUTIVE_REQUIRED and not event_latched:
                print("[AUTO EVENT] Threshold exceeded")
                insert_event()
                event_latched = True

            print(f"[rms] {rms:.2f} dB  | consecutive={consecutive}")

        time.sleep(INTERVAL_SEC)


if __name__ == "__main__":
    main()

