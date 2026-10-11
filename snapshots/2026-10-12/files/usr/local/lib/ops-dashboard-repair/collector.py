#!/usr/bin/env python3
"""Read-only OPS collection and atomic publication. Standard library only."""
import argparse
import contextlib
import fcntl
import json
import math
import os
from pathlib import Path
import re
import socket
import sqlite3
import subprocess
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from urllib.parse import quote

UTC = timezone.utc
UNITS = ['dump1090-fa.service', 'readsb.service', 'ops-audio-ring.service',
         'rms-ring-sampler.service', 'rms-api.service', 'fr24feed.service',
         'pfclient.service', 'adsbexchange-feed.service', 'adsbexchange-mlat.service',
         'airplanes-feed.service', 'airplanes-mlat.service', 'backup-rsync.service',
         'backup-dd.service', 'feed-status.service']

def iso(dt):
    return dt.astimezone(UTC).strftime('%Y-%m-%dT%H:%M:%SZ')

def timestamp(value):
    if not isinstance(value, str) or not value:
        return None
    try:
        dt = datetime.fromisoformat(value.replace('Z', '+00:00'))
        # Historical backup/feed timestamps without an offset were generated in JST.
        return dt.replace(tzinfo=timezone(timedelta(hours=9))) if dt.tzinfo is None else dt
    except ValueError:
        return None

def at(root, absolute):
    return Path(root) / absolute.lstrip('/')

def read_json(path):
    with Path(path).open(encoding='utf-8') as f:
        return json.load(f)

def atomic_json(path, data):
    path = Path(path)
    missing = []
    parent = path.parent
    while not parent.exists():
        missing.append(parent)
        parent = parent.parent
    path.parent.mkdir(parents=True, exist_ok=True)
    # Newly created public folders must remain readable even under root umask 077.
    if '/var/www/html/' in str(path):
        for directory in missing:
            os.chmod(directory, 0o755)
    fd, name = tempfile.mkstemp(prefix='.' + path.name + '.', dir=path.parent)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            json.dump(data, f, ensure_ascii=False, allow_nan=False, indent=2)
            f.write('\n')
            f.flush()
            os.fsync(f.fileno())
            os.fchmod(f.fileno(), 0o644)
        os.replace(name, path)
        dirfd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(dirfd)
        finally:
            os.close(dirfd)
    finally:
        if os.path.exists(name):
            os.unlink(name)

def command(args):
    try:
        p = subprocess.run(args, text=True, capture_output=True, timeout=8)
        return p.returncode, p.stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        return 1, ''

def system_facts():
    facts = {'services': {}, 'host': socket.gethostname(), 'errors': []}
    properties = 'Id,LoadState,ActiveState,UnitFileState,MainPID,ControlGroup'
    rc, text = command(['systemctl', 'show', *UNITS, '--property=' + properties])
    for block in text.split('\n\n'):
        values = dict(line.split('=', 1) for line in block.splitlines() if '=' in line)
        if values.get('Id'):
            facts['services'][values['Id']] = values
    if not facts['services']:
        facts['errors'].append('systemctlによる状態取得が不完全です')
    rc, text = command(['systemctl', '--failed', '--no-legend', '--plain', '--no-pager'])
    facts['failed_units'] = len(text.splitlines()) if rc == 0 else None
    rc, text = command(['ss', '-Htnp', 'state', 'established'])
    facts['connections'] = text.splitlines() if rc == 0 else None
    facts['backup_mounted'] = os.path.ismount('/mnt/backup')
    rc, text = command(['sensors'])
    m = re.search(r'(?:Package id 0|Tctl|temp1):\s*\+?(-?\d+(?:\.\d+)?)', text)
    facts['cpu_temp'] = float(m[1]) if rc == 0 and m else None
    try:
        facts['uptime'] = Path('/proc/uptime').read_text().split()[0] + ' seconds'
        facts['load'] = ', '.join(Path('/proc/loadavg').read_text().split()[:3])
        st = os.statvfs('/')
        used = st.f_blocks - st.f_bfree
        denominator = used + st.f_bavail
        facts['disk_pct'] = round(100 * used / denominator) if denominator else None
    except (OSError, ValueError):
        facts['uptime'], facts['load'], facts['disk_pct'] = None, None, None
    return facts

def service(facts, unit):
    v = facts.get('services', {}).get(unit, {})
    if v.get('LoadState') != 'loaded':
        return 'unknown'
    return v.get('ActiveState') or 'unknown'

def receiver(facts):
    for unit in ('dump1090-fa.service', 'readsb.service'):
        if facts.get('services', {}).get(unit, {}).get('LoadState') == 'loaded':
            return unit
    return None

def network(facts, unit, root):
    """Attribute established remote connections to the unit's own cgroup PIDs."""
    if facts.get('connections') is None:
        return 'UNKNOWN'
    v = facts.get('services', {}).get(unit, {})
    pids = {str(v.get('MainPID', '0'))} - {'0', ''}
    group = v.get('ControlGroup', '')
    if group.startswith('/') and '..' not in Path(group).parts:
        folder = at(root, '/sys/fs/cgroup' + group)
        try:
            for f in folder.rglob('cgroup.procs'):
                pids.update(f.read_text().split())
        except OSError:
            pass
    for line in facts.get('connections', []):
        fields = line.split()
        peer_index = 4 if fields and fields[0] in ('ESTAB', 'ESTABLISHED') else 3
        if len(fields) <= peer_index:
            continue
        peer = fields[peer_index].rsplit(':', 1)[0].strip('[]')
        if peer in ('127.0.0.1', '::1') or peer.startswith('127.'):
            continue
        if pids.intersection(re.findall(r'pid=(\d+)', line)):
            return 'ESTABLISHED'
    # Established outbound traffic is a transport observation, not remote acceptance.
    return 'UNKNOWN'

@contextlib.contextmanager
def database(path):
    con = sqlite3.connect(Path(path).resolve().as_uri() + '?mode=ro', uri=True, timeout=3)
    try:
        con.execute('PRAGMA query_only=ON')
        yield con
    finally:
        con.close()

def audio_url(root, value):
    if not isinstance(value, str):
        return None
    for sub, endpoint in [('button_boom_wav', 'button'), ('auto_boom_wav', 'auto')]:
        base = Path('/home/taku/recordings/events') / sub
        try:
            relative = Path(value).relative_to(base)
        except ValueError:
            continue
        if len(relative.parts) != 1 or relative.suffix.lower() != '.wav':
            return None
        actual_base = at(root, str(base)).resolve()
        actual = at(root, value).resolve()
        if actual.parent != actual_base or not actual.is_file():
            return None
        return '/audio-events/' + endpoint + '/' + quote(relative.name, safe='')
    return None

def backup_job(root, facts, kind, now):
    unit = 'backup-' + kind + '.service'
    if service(facts, unit) in ('active', 'activating'):
        return {'name': kind, 'state': 'running', 'last_run': None, 'message': '実行中'}
    try:
        d = read_json(at(root, '/var/log/backup/' + kind + '.last_status.json'))
        if not isinstance(d, dict):
            raise ValueError('status is not an object')
        completed = timestamp(d.get('ts_end'))
        if completed is None:
            raise ValueError('completion timestamp is missing')
        age = (now - completed).total_seconds()
        result = d.get('result')
        if result not in ('OK', 'NG'):
            raise ValueError('unknown result')
        state = 'done' if result == 'OK' and d.get('exit_code') == 0 else 'error'
        threshold = 26 * 3600 if kind == 'rsync' else 40 * 86400
        if state == 'done' and (age < -300 or age > threshold):
            state = 'stale'
        name = Path(str(d.get('dest', ''))).name or None
        if kind == 'dd':
            destination = Path(str(d.get('dest', '')))
            try:
                relative = destination.relative_to('/mnt/backup/dd')
                if '..' in relative.parts or not (destination.name.endswith('.img.gz') or destination.name.endswith('.img.zst')):
                    raise ValueError('not a DD image')
            except ValueError:
                state = 'error'
            image = at(root, str(destination))
            if not image.is_file() or image.stat().st_size == 0:
                state = 'error'
        return {'name': kind, 'state': state, 'last_run': iso(completed),
                'message': str(d.get('reason') or result), 'file': name,
                'age_seconds': round(age), 'exit_code': d.get('exit_code')}
    except (OSError, ValueError, TypeError) as e:
        return {'name': kind, 'state': 'unknown', 'last_run': None,
                'message': '成功記録を確認できません: ' + str(e)}

def collect(root=Path('/'), facts=None, now=None):
    root = Path(root)
    if facts is None and root != Path('/'):
        raise ValueError('An isolated root requires explicit test facts')
    facts = system_facts() if facts is None else facts
    now = now or datetime.now(UTC)
    errors = list(facts.get('errors', []))
    unit = receiver(facts)
    aircraft = {'count': None, 'updated_at': None, 'state': 'unknown', 'messages': None}
    if unit:
        folder = '/run/dump1090-fa' if unit.startswith('dump1090') else '/run/readsb'
        try:
            d = read_json(at(root, folder + '/aircraft.json'))
            if not isinstance(d.get('aircraft'), list):
                raise ValueError('aircraft must be an array')
            # Decoder's own epoch is more useful than a copied file's mtime.
            source_time = datetime.fromtimestamp(float(d['now']), UTC)
            age = (now - source_time).total_seconds()
            aircraft.update(count=len(d['aircraft']), updated_at=iso(source_time),
                            state='ok' if -10 <= age <= 120 else 'stale')
            try:
                stats = read_json(at(root, folder + '/stats.json'))
                aircraft['messages'] = stats.get('total', {}).get('messages')
            except (OSError, ValueError, AttributeError):
                pass
        except (OSError, ValueError, KeyError, TypeError, OverflowError, AttributeError) as e:
            errors.append('ADS-Bデータ取得不能: ' + str(e))
    else:
        errors.append('ADS-B受信サービスが見つかりません')
    events = {'available': False, 'boom_24h': None, 'rows': [], 'latest_at': None}
    try:
        with database(at(root, '/home/taku/ops-audio-vnext/audio.db')) as con:
            lower = iso(now - timedelta(hours=24))
            events['boom_24h'] = con.execute(
                'SELECT COUNT(*) FROM unified_events WHERE julianday(ts_utc) >= julianday(?) '
                'AND julianday(ts_utc) <= julianday(?)', (lower, iso(now))).fetchone()[0]
            rows = con.execute('SELECT ts_utc,source,wav_path,cut_status FROM unified_events '
                               'ORDER BY ts_utc DESC LIMIT 10').fetchall()
            events['rows'] = [{'ts_utc': t, 'source': src, 'url': audio_url(root, wav),
                               'cut_status': st or 'unknown'} for t, src, wav, st in rows]
            events['latest_at'] = rows[0][0] if rows else None
            events['available'] = True
    except (OSError, sqlite3.Error, ValueError) as e:
        errors.append('音声イベントDB取得不能: ' + str(e))
    rms = {'available': False, 'latest_at': None, 'latest_db': None, 'state': 'unknown', 'series': []}
    try:
        with database(at(root, '/var/lib/ops-audio/boom_rms.db')) as con:
            row = con.execute('SELECT ts_utc,rms_db FROM rms_history ORDER BY id DESC LIMIT 1').fetchone()
            if row:
                parsed = timestamp(row[0])
                if parsed is None or not math.isfinite(float(row[1])):
                    raise ValueError('invalid RMS sample')
                age = (now - parsed).total_seconds()
                rms.update(available=True, latest_at=iso(parsed), latest_db=float(row[1]),
                           state='ok' if -10 <= age <= 120 else 'stale')
            points = con.execute("SELECT substr(ts_utc,1,16)||':00Z',AVG(rms_db) FROM rms_history "
                                 'WHERE ts_utc >= ? AND ts_utc <= ? GROUP BY substr(ts_utc,1,16) '
                                 'ORDER BY 1', (iso(now - timedelta(hours=24)), iso(now))).fetchall()
            rms['series'] = [[t, float(v)] for t, v in points if v is not None and math.isfinite(float(v))]
    except (OSError, sqlite3.Error, ValueError, TypeError) as e:
        errors.append('RMS取得不能: ' + str(e))
    lowfreq = {'available': False, 'generated_at_jst': now.astimezone(timezone(timedelta(hours=9))).isoformat(),
               'latest_at': None, 'today': [], 'total': [], 'state': 'unknown'}
    try:
        with database(at(root, '/home/taku/ops-audio-vnext/audio.db')) as con:
            today = now.astimezone(timezone(timedelta(hours=9))).date().isoformat()
            lowfreq['today'] = [{'class': k, 'count': n} for k, n in con.execute(
                "SELECT class,COUNT(*) FROM audio_features WHERE date(ts_utc,'+9 hours')=? GROUP BY class", (today,))]
            lowfreq['total'] = [{'class': k, 'count': n} for k, n in con.execute(
                'SELECT class,COUNT(*) FROM audio_features GROUP BY class')]
            lowfreq['latest_at'] = con.execute('SELECT MAX(ts_utc) FROM audio_features').fetchone()[0]
            latest = timestamp(lowfreq['latest_at'])
            lowfreq['available'] = True
            lowfreq['state'] = 'ok' if latest and -300 <= (now-latest).total_seconds() <= 86400 else 'stale'
    except (OSError, sqlite3.Error) as e:
        errors.append('低周波集計取得不能: ' + str(e))
    feeds = []
    for name, feedunit in [('ADSBX', 'adsbexchange-feed.service'), ('FR24', 'fr24feed.service'), ('PlaneFinder', 'pfclient.service')]:
        feeds.append({'name': name, 'service': feedunit, 'state': service(facts, feedunit),
                      'network': network(facts, feedunit, root), 'timestamp': iso(now)})
    ring = service(facts, 'ops-audio-ring.service')
    feeds.append({'name': 'AudioRecorder', 'service': 'ops-audio-ring.service',
                  'state': 'OK' if ring == 'active' and rms['state'] == 'ok' else 'UNKNOWN' if ring == 'unknown' else 'NG',
                  'reason': '録音サービス=' + ring + ', RMS=' + rms['state'], 'checked_at': iso(now)})
    jobs = [backup_job(root, facts, k, now) for k in ('rsync', 'dd')]
    if not facts.get('backup_mounted'):
        errors.append('バックアップ先がマウントされていません')
    return {'version': 1, 'generated_at': iso(now), 'host': facts.get('host', 'unknown'),
            'services': {k: service(facts, k) for k in UNITS},
            'system': {'failed_units': facts.get('failed_units'), 'cpu_temp': facts.get('cpu_temp'),
                       'disk_pct': facts.get('disk_pct'), 'uptime': facts.get('uptime'), 'load': facts.get('load')},
            'receiver': unit, 'aircraft': aircraft, 'events': events, 'rms': rms,
            'lowfreq': lowfreq, 'feeds': feeds, 'backup': {'mounted': bool(facts.get('backup_mounted')), 'jobs': jobs},
            'fingerprint': {'available': False, 'status': '未提供', 'reason': '検証済みの学習データ生成元がありません'},
            'errors': errors}

def outputs(d):
    services, system = d['services'], d['system']
    dd = d['backup']['jobs'][1]
    health = {'host': d['host'], 'time': d['generated_at'], 'uptime': system['uptime'], 'load': system['load'],
              'disk_root': str(system['disk_pct'])+'%' if system['disk_pct'] is not None else None,
              'cpu_temp': str(system['cpu_temp'])+'C' if system['cpu_temp'] is not None else None,
              'audio_core_state': services['ops-audio-ring.service'],
              'adsb_state': services.get(d['receiver'], 'unknown'), 'fr24_state': services['fr24feed.service'],
              'pf_state': services['pfclient.service'], 'aircraft_count': d['aircraft']['count'],
              'aircraft_messages': d['aircraft']['messages'], 'aircraft_state': d['aircraft']['state'],
              'rms_summary': d['rms'], 'last_event_row': d['events']['rows'][0] if d['events']['rows'] else None,
              'last_dd_name': dd.get('file'), 'dd_state': dd['state'], 'errors': d['errors']}
    ops = {'generated_at': d['generated_at'], 'audio_ring': services['ops-audio-ring.service'],
           'rms_sampler': services['rms-ring-sampler.service'], 'rms_api': services['rms-api.service'],
           'audio_recorder': services['ops-audio-ring.service'], 'backup_rsync': services['backup-rsync.service'],
           'failed_units': system['failed_units'], 'boom_24h': d['events']['boom_24h'],
           'feed_last': ' / '.join(d['errors']) or 'snapshot collected', 'errors': d['errors']}
    data = {'/status/dashboard.json': d, '/status/ops_health.json': health, '/status/ops_unified.json': ops,
            '/backup-logs/status.json': {'version': 2, 'updated': d['generated_at'], **d['backup']},
            '/status/lowfreq_summary.json': d['lowfreq'],
            '/status/audio_detect_status.json': {'updated_at': d['generated_at'], **d['rms']},
            '/recordings/data/boom_24h.json': {'generated_at': d['generated_at'], 'available': d['events']['available'], 'boom_24h': d['events']['boom_24h']},
            '/recordings/data/unified_events.json': [{'ts_utc': r['ts_utc'], 'source': r['source'], 'wav_path': r['url'], 'cut_status': r['cut_status']} for r in d['events']['rows']],
            '/status/audio_fingerprint_summary.json': {'updated_at': d['generated_at'], **d['fingerprint']}}
    for feed, filename in zip(d['feeds'], ['adsbx', 'fr24', 'pf', 'audio_recorder']):
        data['/feed_status_' + filename + '.json'] = feed
    data['/feed_status.json'] = {
        'local_rx': 'ON' if d['aircraft']['state'] == 'ok' else 'UNKNOWN',
        'tar1090': 'UNKNOWN', 'FR24': 'ON' if services['fr24feed.service'] == 'active' else 'OFF',
        'ADSBx': 'ON' if services['adsbexchange-feed.service'] == 'active' else 'OFF',
        'airplanes_live': 'ON' if services['airplanes-feed.service'] == 'active' else 'OFF',
        'airplanes_mlat': 'ON' if services['airplanes-mlat.service'] == 'active' else 'OFF',
        'ryukyu': 'UNKNOWN', 'timestamp': d['generated_at']}
    return data

def publish(root, data):
    # Snapshot is the commit marker: compatibility JSON first, dashboard last.
    entries = list(outputs(data).items())
    entries.sort(key=lambda item: item[0] == '/status/dashboard.json')
    for name, value in entries:
        atomic_json(at(root, '/var/www/html' + name), value)

def selftest(data):
    failures = []
    if not data['backup']['mounted']:
        failures.append('backup mount is unavailable')
    for job in data['backup']['jobs']:
        if job['state'] != 'done':
            failures.append(job['name'] + ': ' + job['state'])
    return failures

def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest='action', required=True)
    p = sub.add_parser('collect')
    p.add_argument('--root', default='/')
    p.add_argument('--facts', help='fixture JSON; required for an isolated root')
    p.add_argument('--selftest', action='store_true')
    p = sub.add_parser('write-backup')
    p.add_argument('kind', choices=['dd', 'rsync'])
    for name in ('started', 'ended', 'host', 'destination', 'result', 'reason', 'code'):
        p.add_argument(name)
    args = parser.parse_args()
    if args.action == 'write-backup':
        atomic_json('/var/log/backup/'+args.kind+'.last_status.json',
                    {'ts_start': args.started, 'ts_end': args.ended, 'host': args.host,
                     'dest': args.destination, 'mount_point': '/mnt/backup', 'result': args.result,
                     'reason': args.reason, 'exit_code': int(args.code)})
        return 0
    root = Path(args.root).resolve()
    if root != Path('/') and not args.facts:
        parser.error('--root requires --facts; system commands are disabled in isolated roots')
    lock = at(root, '/run/ops-dashboard-publish.lock')
    lock.parent.mkdir(parents=True, exist_ok=True)
    with lock.open('a') as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        data = collect(root, read_json(args.facts) if args.facts else None)
        publish(root, data)
        if args.selftest:
            failures = selftest(data)
            path = at(root, '/var/www/html/backup/selftest.status')
            path.parent.mkdir(parents=True, exist_ok=True)
            # Text publication uses the same atomic helper mechanics below.
            text = 'Backup Self-Test @ '+data['generated_at']+'\nRESULT='+('NG' if failures else 'OK')+'\n'
            text += '\n'.join(failures or ['mount and recent successful job records checked; restore not tested'])+'\n'
            fd, name = tempfile.mkstemp(prefix='.selftest.', dir=path.parent)
            try:
                with os.fdopen(fd, 'w') as f:
                    f.write(text); f.flush(); os.fsync(f.fileno()); os.fchmod(f.fileno(), 0o644)
                os.replace(name, path)
            finally:
                if os.path.exists(name): os.unlink(name)
            print(text.strip())
            return 1 if failures else 0
        print('OPS snapshot published: '+data['generated_at'])
        return 1 if data['errors'] else 0

if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, sqlite3.Error) as exc:
        print('OPS publication failed: '+str(exc), file=sys.stderr)
        sys.exit(1)
