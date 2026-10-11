#!/usr/bin/env python3
# ROLE: UNKNOWN
# ============================================================
# File    : /usr/local/bin/unified-events-web.py
# Version : 1.0.0-A+++
# Updated : 2026-04-23
#
# Purpose :
#   unified_events から AUTO/BUTTON 統合Webページを生成する
#
# Output :
#   /var/www/html/status/unified_events.html
# ============================================================

import html
import os
import sqlite3
import tempfile
from datetime import datetime, timedelta, timezone

DB = "/home/taku/ops-audio-vnext/audio.db"
OUT_HTML = "/var/www/html/status/unified_events.html"
LIMIT_ROWS = 100


def jst_text(ts_utc: str) -> str:
    try:
        dt = datetime.strptime(ts_utc, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
        jst = dt.astimezone(timezone(timedelta(hours=9)))
        return jst.strftime("%Y-%m-%d %H:%M:%S JST")
    except Exception:
        return ts_utc


def audio_link(path: str) -> str:
    if not path:
        return "-"

    base = os.path.basename(path)

    if "/home/taku/recordings/events/button_boom_wav/" in path:
        url = f"/audio-events/button/{html.escape(base)}"
    elif "/home/taku/recordings/events/auto_boom_wav/" in path:
        url = f"/audio-events/auto/{html.escape(base)}"
    else:
        return html.escape(base)

    return f'''
<a href="{url}" target="_blank">{html.escape(base)}</a><br>
<audio controls preload="none" style="width:240px;">
  <source src="{url}" type="audio/wav">
</audio>
'''

def atomic_page(path, page):
    fd, temporary = tempfile.mkstemp(prefix='.unified-events.', dir=os.path.dirname(path))
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            f.write(page)
            f.flush()
            os.fsync(f.fileno())
            os.fchmod(f.fileno(), 0o644)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)

def main() -> None:
    os.makedirs(os.path.dirname(OUT_HTML), exist_ok=True)

    with sqlite3.connect(DB, timeout=10) as con:
        con.execute("PRAGMA busy_timeout = 10000")

        counts = con.execute(
            """
            SELECT source, COUNT(*)
            FROM unified_events
            WHERE ts_utc >= strftime('%Y-%m-%dT%H:%M:%SZ','now','-24 hours')
            GROUP BY source
            ORDER BY source
            """
        ).fetchall()

        rows = con.execute(
            """
            SELECT id, ts_utc, source, wav_path, note, cut_status, cut_error
            FROM unified_events
            ORDER BY ts_utc DESC
            LIMIT ?
            """,
            (LIMIT_ROWS,),
        ).fetchall()

    count_map = {k: v for k, v in counts}
    auto_24h = count_map.get("AUTO", 0)
    button_24h = count_map.get("BUTTON", 0)

    table_rows = []
    for row_id, ts_utc, source, wav_path, note, cut_status, cut_error in rows:
        table_rows.append(
            f"""
<tr>
  <td>{row_id}</td>
  <td>{html.escape(ts_utc)}</td>
  <td>{html.escape(jst_text(ts_utc))}</td>
  <td>{html.escape(source or '')}</td>
  <td>{audio_link(wav_path or '')}</td>
  <td>{html.escape(note or '')}</td>
  <td>{html.escape(cut_status or '')}</td>
  <td>{html.escape(cut_error or '')}</td>
</tr>
"""
        )

    page = f"""<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<title>Unified Events</title>
<style>
body {{
  font-family: sans-serif;
  margin: 24px;
  line-height: 1.5;
}}
h1, h2 {{
  margin: 0 0 12px 0;
}}
.card {{
  border: 1px solid #ccc;
  border-radius: 8px;
  padding: 12px 16px;
  margin-bottom: 16px;
  background: #fafafa;
}}
table {{
  border-collapse: collapse;
  width: 100%;
  font-size: 14px;
}}
th, td {{
  border: 1px solid #ccc;
  padding: 6px 8px;
  text-align: left;
  vertical-align: top;
}}
th {{
  background: #f0f0f0;
}}
.small {{
  color: #666;
  font-size: 12px;
}}
</style>
</head>
<body>
<h1>Unified Events</h1>

<div class="card">
  <h2>24h Summary</h2>
  <div>AUTO   : {auto_24h}</div>
  <div>BUTTON : {button_24h}</div>
  <div class="small">Generated: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}</div>
</div>

<div class="card">
  <h2>Recent {LIMIT_ROWS} Events</h2>
  <table>
    <thead>
      <tr>
        <th>ID</th>
        <th>UTC</th>
        <th>JST</th>
        <th>Source</th>
        <th>WAV</th>
        <th>Note</th>
        <th>Cut Status</th>
        <th>Cut Error</th>
      </tr>
    </thead>
    <tbody>
      {''.join(table_rows)}
    </tbody>
  </table>
</div>
</body>
</html>
"""

    atomic_page(OUT_HTML, page)

    print(f"[OK] wrote: {OUT_HTML}", flush=True)


if __name__ == "__main__":
    main()
