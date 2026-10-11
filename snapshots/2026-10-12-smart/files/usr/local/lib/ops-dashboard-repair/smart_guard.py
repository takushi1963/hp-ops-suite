#!/usr/bin/python3
import argparse,datetime,json,os,subprocess,tempfile
from pathlib import Path

def verdict(data,code):
    if not isinstance(data,dict):return False,'Invalid SMART JSON'
    status=data.get('smartctl',{}).get('exit_status')
    if type(status) is not int or status!=code:return False,'Missing or inconsistent SMART exit status'
    if code!=0:return False,'SMART exit bitmask: '+str(code)
    if data.get('smart_status',{}).get('passed') is not True:return False,'SMART health is not confirmed passed'
    return True,'SMART passed; exit status 0'

def main():
    p=argparse.ArgumentParser();p.add_argument('device');p.add_argument('--log-dir',default='/var/log/backup/smart');a=p.parse_args()
    if a.device!='/dev/sda':p.error('Only configured backup device /dev/sda is accepted')
    now=datetime.datetime.now().astimezone().isoformat()
    try:
        r=subprocess.run(['/usr/sbin/smartctl','-H','-j',a.device],capture_output=True,text=True,timeout=30)
        try:data=json.loads(r.stdout);ok,reason=verdict(data,r.returncode)
        except (ValueError,TypeError,AttributeError):data=None;ok=False;reason='Invalid SMART JSON'
        record={'captured_at':now,'device':a.device,'process_returncode':r.returncode,'ok':ok,'reason':reason,'stdout':r.stdout,'stderr':r.stderr}
    except (OSError,subprocess.TimeoutExpired) as exc:
        ok=False;reason='SMART query failed: '+str(exc);record={'captured_at':now,'device':a.device,'ok':False,'reason':reason}
    directory=Path(a.log_dir);directory.mkdir(parents=True,exist_ok=True,mode=0o700)
    fd,name=tempfile.mkstemp(prefix='.smart-',dir=directory)
    try:
        with os.fdopen(fd,'w') as f:json.dump(record,f,indent=2);f.write('\n');f.flush();os.fsync(f.fileno())
        dest=directory/(datetime.datetime.now().strftime('%Y%m%dT%H%M%S')+'-'+str(os.getpid())+'.json');os.replace(name,dest)
    finally:
        if os.path.exists(name):os.unlink(name)
    print(reason+'; diagnostic: '+str(dest))
    return int(not ok)
if __name__=='__main__':raise SystemExit(main())
