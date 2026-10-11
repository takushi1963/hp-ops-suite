#!/usr/bin/python3
import argparse, fcntl, json, math, re, sqlite3, subprocess
from pathlib import Path

def band(path, hp, lp):
    p = subprocess.run(['/usr/bin/ffmpeg', '-nostdin', '-hide_banner', '-nostats', '-i', str(path), '-t', '60', '-af', f'aformat=channel_layouts=mono,highpass=f={hp},lowpass=f={lp},astats=metadata=0:reset=0', '-f', 'null', '-'], capture_output=True, text=True, timeout=20)
    if p.returncode:
        raise ValueError(p.stderr[-1000:])
    def number(label):
        matches = re.findall(re.escape(label) + r':\s*([^\s]+)', p.stderr)
        if not matches:
            raise ValueError('Missing measurement: ' + label)
        n = float(matches[-1])
        if label == 'RMS level dB' and n == -math.inf:
            return -120.0
        if not math.isfinite(n):
            raise ValueError('Non-finite measurement: ' + label)
        return n
    return number('RMS level dB'), number('Zero crossings rate')

def analyze(path):
    low, lz = band(path, 20, 120)
    mid, mz = band(path, 120, 1000)
    diff = low - mid
    cls = ('LOWFREQ_STRONG' if low > -40 and diff >= 3 else
           'LOWFREQ_BODY' if low > -48 and diff >= 3 and lz < .015 else
           'MID_BAND_LOUD' if mid > -40 else 'QUIET_OR_WEAK')
    return low, mid, diff, lz, mz, cls

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--db', default='/home/taku/ops-audio-vnext/audio.db')
    p.add_argument('--limit', type=int, default=20)
    p.add_argument('--dry-run', action='store_true')
    a = p.parse_args()
    if not 1 <= a.limit <= 100:
        p.error('--limit must be 1..100')
    with Path(a.db + '.band-analysis.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print('Analysis already running')
            return 0
        db = sqlite3.connect(Path(a.db).resolve().as_uri() + '?mode=' + ('ro' if a.dry_run else 'rw'), uri=True, timeout=10)
        rows = db.execute('''SELECT e.id,e.source,e.ts_utc,e.wav_path FROM unified_events e
          WHERE e.wav_path IS NOT NULL AND e.wav_path != ''
          AND julianday(e.ts_utc) >= julianday('now','-7 days')
          AND NOT EXISTS(SELECT 1 FROM audio_features f WHERE f.event_id=e.id)
          ORDER BY julianday(e.ts_utc) DESC LIMIT ?''', (a.limit * 10,)).fetchall()
        done = errors = missing = 0
        for eid, source, ts, wav in rows:
            if done + errors >= a.limit:
                break
            path = Path(wav)
            if not path.is_file():
                missing += 1
                continue
            try:
                if path.stat().st_size > 20000000:
                    raise ValueError('Input exceeds 20 MB')
                values = analyze(path)
                if not a.dry_run:
                    with db:
                        db.execute('''INSERT INTO audio_features(event_id,source,ts_utc,wav_path,
                        low_rms_db,mid_rms_db,low_minus_mid_db,low_zcr,mid_zcr,class)
                        VALUES(?,?,?,?,?,?,?,?,?,?) ON CONFLICT(event_id) DO NOTHING''', (eid,source,ts,wav,*values))
                done += 1
                print(json.dumps({'event_id':eid,'class':values[-1],'low_db':values[0],'mid_db':values[1]}))
            except (ValueError, OSError, subprocess.TimeoutExpired, sqlite3.Error) as exc:
                errors += 1
                print(json.dumps({'event_id':eid,'error':str(exc)}))
        db.close()
        print(json.dumps({'analyzed':done,'missing':missing,'errors':errors,'dry_run':a.dry_run}))
        return int(errors > 0)

if __name__ == '__main__':
    raise SystemExit(main())
