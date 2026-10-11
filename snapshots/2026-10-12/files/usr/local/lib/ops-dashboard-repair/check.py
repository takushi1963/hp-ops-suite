#!/usr/bin/python3
import argparse,datetime,json,sys
from pathlib import Path

def check(data,kind,now=None):
    now=now or datetime.datetime.now(datetime.timezone.utc)
    stamp=datetime.datetime.fromisoformat(data['generated_at'].replace('Z','+00:00'))
    age=(now-stamp).total_seconds()
    if not 0 <= age <= 120: return ['NG: monitoring snapshot is stale or future-dated']
    failures=[]
    if kind=='audio':
        rms=data.get('rms',{})
        if rms.get('state')!='ok': failures.append('NG: RMS '+str(rms.get('state','missing')))
        for service in ('ops-audio-ring.service','rms-ring-sampler.service'):
            if data.get('services',{}).get(service)!='active': failures.append('NG: '+service+' inactive or missing')
    else:
        backup=data.get('backup',{})
        if backup.get('mounted') is not True: failures.append('NG: backup mount unavailable')
        jobs={j['name']:j for j in backup.get('jobs',[])}
        for name in ('rsync','dd'):
            state=jobs.get(name,{}).get('state','missing')
            if state not in ('done','running'): failures.append('NG: '+name+' '+state)
    return failures

def main():
    p=argparse.ArgumentParser();p.add_argument('kind',choices=['audio','backup']);p.add_argument('--snapshot',default='/var/www/html/status/dashboard.json');a=p.parse_args()
    try:
        failures=check(json.loads(Path(a.snapshot).read_text()),a.kind)
    except (OSError,ValueError,KeyError,TypeError) as exc:
        failures=['NG: invalid monitoring snapshot: '+str(exc)]
    print('\n'.join(failures) if failures else 'OK: '+a.kind+' current monitoring checks passed')
    return int(bool(failures))
if __name__=='__main__':sys.exit(main())
