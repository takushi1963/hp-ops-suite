import argparse,datetime,hashlib,json,os,shutil,subprocess
from pathlib import Path
b=Path(__file__).resolve().parent
p=argparse.ArgumentParser();p.add_argument('--apply',action='store_true');p.add_argument('--rollback',type=Path);a=p.parse_args()
if a.rollback:
    if os.geteuid()!=0:p.error('root required')
    for item in reversed(json.loads(a.rollback.read_text())):
        dst=Path(item['target'])
        if item['backup']:shutil.copy2(item['backup'],dst)
        else:dst.unlink(missing_ok=True)
    pass;raise SystemExit(0)
items=json.loads((b/'manifest.json').read_text())
for item in items:
    dst=Path(item['target']);sha=hashlib.sha256(dst.read_bytes()).hexdigest() if dst.exists() else None
    if sha!=item['sha']:p.error('Source changed: '+str(dst))
    print('Install:',dst)
if not a.apply:print('Plan only');raise SystemExit(0)
if os.geteuid()!=0:p.error('root required')
backup=Path('/var/backups/ops-layout-restore')/(datetime.datetime.now().strftime('%Y%m%dT%H%M%S')+'-'+str(os.getpid()));backup.mkdir(parents=True,mode=0o700)
records=[]
for i,item in enumerate(items):
    dst=Path(item['target']);old=backup/str(i) if dst.exists() else None
    if old:shutil.copy2(dst,old)
    records.append({'target':str(dst),'backup':str(old) if old else None})
rollback=backup/'rollback.json';rollback.write_text(json.dumps(records,indent=2))
try:
    for item in items:
        dst=Path(item['target']);dst.parent.mkdir(parents=True,exist_ok=True)
        temp=dst.with_name(dst.name+'.health-'+str(os.getpid()));shutil.copyfile(b/item['payload'],temp);temp.chmod(item['mode']);os.chown(temp,dst.stat().st_uid,dst.stat().st_gid) if dst.exists() else None;os.replace(temp,dst)
    pass
except BaseException:
    for item in reversed(records):
        dst=Path(item['target'])
        if item['backup']:shutil.copy2(item['backup'],dst)
        else:dst.unlink(missing_ok=True)
    raise
print('Rollback: sudo python3',b/'install.py','--rollback',rollback)
print('Layout restored. Collector and backup jobs were not run.')
