"""Host-side file operations, invoked in a no-network container by run-host.sh.
Fixed mounts only: /target-home, /stack, /state, /package. No secrets printed.
"""
import argparse
import hashlib
import json
import os
import tempfile
from pathlib import Path

BASE = 'sha256:9ed081da116daa3036ac32bd06b8a0069eaec540ad6239de4611c7a6df9ecf97'
HOME = Path('/target-home')
STACK = Path('/stack')
STATE = Path('/state')


def atomic(path, data, mode=0o600, uid=0, gid=0, create_only=False):
    if path.is_symlink():
        raise ValueError('Refusing symbolic link target: '+str(path))
    fd,name = tempfile.mkstemp(prefix='.'+path.name+'.',suffix='.new',dir=path.parent)
    temp = Path(name)
    try:
        with os.fdopen(fd,'wb') as stream:
            stream.write(data)
            stream.flush()
            os.fchmod(stream.fileno(),mode)
            os.fchown(stream.fileno(),uid,gid)
            os.fsync(stream.fileno())
        if create_only:
            os.link(temp,path,follow_symlinks=False)
        else:
            os.replace(temp,path)
    finally:
        temp.unlink(missing_ok=True)


def put_json(path,value,**kw):
    atomic(path,(json.dumps(value,indent=2)+'\n').encode(),**kw)


def stage_config():
    # Approved pairing is an external input. Never export the identifier in evidence.
    pairing=HOME/'profiles/moss/platforms/pairing/telegram-approved.json'
    approved=json.loads(pairing.read_text())
    if not isinstance(approved,dict) or len(approved)!=1:
        raise ValueError('Expected exactly one approved Telegram principal; reconcile pairing')
    owner=next(iter(approved))
    if not owner.isdecimal():
        raise ValueError('Unsupported Telegram pairing schema')
    names=('honcho.json','moss-memory-policy.json','moss-memory-gate.key')
    for name in names:
        if (HOME/name).exists() or (HOME/name).is_symlink():
            raise ValueError('Refusing existing configuration: '+name)
    policy={'version':1,'workspace':'moss-rodolfo','profiles':['default','moss'],
            'homes':['/opt/data','/opt/data/profiles/moss'],'telegram_owner_id':owner,
            'password_owner':'Rodolfo','base_url':'http://honcho-api:8000'}
    config={'enabled':False,'environment':'local','baseUrl':'http://honcho-api:8000','apiKey':'local',
            'workspace':'moss-rodolfo','peerName':'Rodolfo','pinUserPeer':True,'aiPeer':'Moss',
            'sessionStrategy':'per-session','saveMessages':True,'a2aSessions':False,
            'writeFrequency':'turn','recallMode':'hybrid','contextTokens':1800,
            'dialecticCadence':2,'dialecticReasoningLevel':'low','reasoningLevelCap':'low',
            'queryRewrite':False,'logging':False,'timeout':20,
            'observation':{'user':{'observeMe':True,'observeOthers':False},
                           'ai':{'observeMe':False,'observeOthers':True}}}
    payloads={
        'moss-memory-gate.key':(os.urandom(32),0o440,0,100),
        'moss-memory-policy.json':((json.dumps(policy,indent=2)+'\n').encode(),0o440,0,100),
        'honcho.json':((json.dumps(config,indent=2)+'\n').encode(),0o600,99,100),
    }
    receipt={name:{'sha256':[hashlib.sha256(data).hexdigest()],'mode':mode,'uid':uid,'gid':gid}
             for name,(data,mode,uid,gid) in payloads.items()}
    put_json(STATE/'config-transaction.json',receipt)
    for name,(data,mode,uid,gid) in payloads.items():
        atomic(HOME/name,data,mode=mode,uid=uid,gid=gid,create_only=True)
    print('configuration_staged_disabled')


def unstage():
    journal=STATE/'config-transaction.json'
    if not journal.exists():
        return
    receipt=json.loads(journal.read_text())
    expected={'moss-memory-gate.key','moss-memory-policy.json','honcho.json'}
    if set(receipt)!=expected: raise ValueError('Invalid staging custody')
    for name,r in receipt.items():
        p=HOME/name
        if p.is_symlink(): raise ValueError('Configuration link drift')
        if not p.exists(): continue
        st=p.stat()
        if ((st.st_uid,st.st_gid,st.st_mode & 0o777)!=(r['uid'],r['gid'],r['mode'])
                or hashlib.sha256(p.read_bytes()).hexdigest() not in r['sha256']):
            raise ValueError('Configuration changed; refusing cleanup: '+name)
    for name in receipt:
        p=HOME/name
        if p.exists(): p.unlink()
    print('owned_staged_configuration_removed')


def enabled(value):
    path=HOME/'honcho.json'
    config=json.loads(path.read_text())
    if config.get('workspace')!='moss-rodolfo': raise ValueError('Workspace drift')
    journal=STATE/'config-transaction.json'
    receipt=json.loads(journal.read_text())
    if hashlib.sha256(path.read_bytes()).hexdigest() not in receipt['honcho.json']['sha256']:
        raise ValueError('Configuration drift before activation')
    config['enabled']=value
    data=(json.dumps(config,indent=2)+'\n').encode()
    planned=hashlib.sha256(data).hexdigest()
    if planned not in receipt['honcho.json']['sha256']:
        receipt['honcho.json']['sha256'].append(planned)
    put_json(journal,receipt)
    atomic(path,data,uid=99,gid=100)
    print('ingestion_enabled' if value else 'ingestion_disabled')


def compose_image(image):
    if not image.startswith('sha256:') or len(image)!=71:
        raise ValueError('Immutable image ID required')
    path=STACK/'compose.yaml'
    original=path.read_bytes()
    needle=('    image: '+BASE+'\n').encode()
    if original.count(needle)!=1: raise ValueError('Moss Compose source changed')
    atomic(STATE/'compose.before.yaml',original)
    updated=original.replace(needle,('    image: '+image+'\n').encode())
    atomic(STATE/'compose.after.sha256',hashlib.sha256(updated).hexdigest().encode())
    atomic(path,updated,mode=0o644,uid=99,gid=100)
    print('canonical_moss_image_updated')


def rollback_compose():
    path=STACK/'compose.yaml'
    if path.read_bytes()==(STATE/'compose.before.yaml').read_bytes():
        print('canonical_compose_already_at_baseline')
        return
    expected=(STATE/'compose.after.sha256').read_text()
    if hashlib.sha256(path.read_bytes()).hexdigest()!=expected:
        raise ValueError('Canonical source drift: refusing rollback overwrite')
    atomic(path,(STATE/'compose.before.yaml').read_bytes(),mode=0o644,uid=99,gid=100)
    print('canonical_compose_restored')


if __name__=='__main__':
    p=argparse.ArgumentParser()
    p.add_argument('operation',choices=['stage','unstage','enable','disable','compose','rollback-compose'])
    p.add_argument('image',nargs='?')
    args=p.parse_args()
    if args.operation=='stage': stage_config()
    elif args.operation=='unstage': unstage()
    elif args.operation=='enable': enabled(True)
    elif args.operation=='disable': enabled(False)
    elif args.operation=='compose': compose_image(args.image)
    elif args.operation=='rollback-compose': rollback_compose()
