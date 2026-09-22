"""Offline helper: snapshot selected mutable state and preserve toolset choices.

Runs only in a no-network, entrypoint-overridden container. /home is the
explicit target home; source/persona files are never modified.
"""
import io,json,os,pathlib,sqlite3,sys,tarfile,tempfile,hashlib
import yaml
ROOT=pathlib.Path('/home')

def config_bytes(data):
    c=yaml.safe_load(data)
    if not isinstance(c,dict): raise ValueError('Invalid config')
    before=json.loads(json.dumps(c))
    known=c.setdefault('known_builtin_toolsets',{})
    if not isinstance(known,dict): raise ValueError('Invalid known_builtin_toolsets')
    for platform,tools in c.get('platform_toolsets',{}).items():
        if not isinstance(tools,list): raise ValueError('Invalid toolsets')
        if 'connections' not in tools:
            values=known.setdefault(platform,[])
            if not isinstance(values,list): raise ValueError('Invalid known toolsets')
            if 'connections' not in values: values.append('connections')
    out=yaml.safe_dump(c,sort_keys=False,allow_unicode=True).encode()
    after=yaml.safe_load(out)
    before.pop('known_builtin_toolsets',None); after.pop('known_builtin_toolsets',None)
    assert after==before
    return out

def configure(expected):
    p=ROOT/'config.yaml'
    if p.is_symlink(): raise ValueError('Symlink config refused')
    data=p.read_bytes()
    if hashlib.sha256(data).hexdigest()!=expected: raise ValueError('Config drift')
    new=config_bytes(data); st=p.stat()
    fd,name=tempfile.mkstemp(prefix='.release-config-',dir=ROOT)
    try:
        os.fchmod(fd,st.st_mode & 0o777); os.fchown(fd,st.st_uid,st.st_gid)
        with os.fdopen(fd,'wb') as f: f.write(new); f.flush(); os.fsync(f.fileno())
        os.replace(name,p)
        d=os.open(ROOT,os.O_DIRECTORY); os.fsync(d); os.close(d)
    finally:
        if os.path.exists(name): os.unlink(name)
    assert p.read_bytes()==new
    print(json.dumps({'config_sha':hashlib.sha256(new).hexdigest()}))

def selected():
    # DBs/configs used by the runtime, not workspace/source caches or attachments.
    roots=[ROOT,ROOT/'webui']
    roots += [p for p in (ROOT/'profiles').glob('*') if p.is_dir() and not p.is_symlink()]
    files=set()
    for r in roots:
        for p in r.iterdir() if r.is_dir() else []:
            if p.is_file() and not p.is_symlink() and (p.suffix in ('.db','.sqlite','.sqlite3') or p.name in ('config.yaml','.env','auth.json','honcho.json','moss-memory-policy.json','moss-memory-gate.key')):
                files.add(p)
    return sorted(files)

def snapshot():
    count=0
    with tarfile.open(fileobj=sys.stdout.buffer,mode='w|') as tar:
        for p in selected():
            if p.suffix in ('.db','.sqlite','.sqlite3'):
                with tempfile.TemporaryDirectory() as td:
                    target=pathlib.Path(td)/'snapshot.db'
                    with sqlite3.connect(p.as_uri()+'?mode=ro',uri=True,timeout=30) as src,sqlite3.connect(target) as dst:
                        src.backup(dst)
                        assert dst.execute('pragma integrity_check').fetchone()[0]=='ok'
                    tar.add(target,arcname=str(p.relative_to(ROOT)),recursive=False)
            else: tar.add(p,arcname=str(p.relative_to(ROOT)),recursive=False)
            count+=1
    if not count: raise RuntimeError('Empty state snapshot')

def verify_snapshot():
    count=0
    with tempfile.TemporaryDirectory() as td:
        with tarfile.open(fileobj=sys.stdin.buffer,mode='r|') as tar:
            for item in tar:
                p=pathlib.PurePosixPath(item.name)
                if not item.isfile() or p.is_absolute() or '..' in p.parts: raise ValueError('Unsafe archive')
                data=tar.extractfile(item)
                if data is None: raise ValueError('Missing archive member')
                if p.suffix in ('.db','.sqlite','.sqlite3'):
                    target=pathlib.Path(td)/'db'
                    with target.open('wb') as f:
                        import shutil
                        shutil.copyfileobj(data,f)
                    with sqlite3.connect(target) as db: assert db.execute('pragma integrity_check').fetchone()[0]=='ok'
                    target.unlink()
                else:
                    while data.read(1024*1024): pass
                count+=1
    if not count: raise ValueError('Empty backup')
    print(json.dumps({'verified_backup_members':count}))

if __name__=='__main__':
    op=sys.argv[1]
    if op=='configure': configure(sys.argv[2])
    elif op=='snapshot': snapshot()
    elif op=='verify-snapshot': verify_snapshot()
    else: raise ValueError(op)
