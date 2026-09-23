"""Host-side fleet transaction; production is changed only by explicit --apply.

Execution survives loss of the Moss caller. Rollback never restores databases or
old messages. A failed image rollout restores only the Compose selectors; the
new config metadata deliberately preserves existing toolset permissions.
"""
import argparse,fcntl,hashlib,json,os,pathlib,shutil,signal,socket,subprocess,sys,time
ROOT=pathlib.Path(__file__).resolve().parent
STACK=pathlib.Path('/mnt/user/appdata/the-ai-crowd')
COMPOSE=STACK/'compose.yaml'
STATE=STACK/'state/private/backups/fleet-release-20260922-r2'
PY='/opt/hermes/.venv/bin/python'
ORDER=['the-elders','richmond','denholm','jen','roy','moss']

def sha(data): return hashlib.sha256(data).hexdigest()
def run(args,**kw):
    kw.setdefault('timeout',60)
    return subprocess.run(args,check=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,**kw).stdout

def docker(*args): return ['docker','--host','unix:///var/run/docker.sock',*args]
def git(*args): return ['git','-c','safe.directory=/mnt/ssd/appdata/the-ai-crowd','-C',str(STACK),*args]
def compose(path,*args):
    return docker('compose','-p','the-ai-crowd','--project-directory',str(STACK),'-f',str(path),*args)
def inspect(s): return json.loads(run(docker('inspect','the-ai-crowd-'+s+'-1')))[0]
def current_image(s):
    ids=run(docker('ps','-aq','--filter','name=^/the-ai-crowd-'+s+'-1$')).strip()
    return inspect(s)['Image'] if ids else None
def atomic(p,data,mode=0o600):
    tmp=p.with_name(p.name+'.new')
    fd=os.open(tmp,os.O_WRONLY|os.O_CREAT|os.O_EXCL,mode)
    try:
        with os.fdopen(fd,'wb') as f: f.write(data); f.flush(); os.fsync(f.fileno())
        os.replace(tmp,p)
        fd=os.open(p.parent,os.O_DIRECTORY); os.fsync(fd); os.close(fd)
    finally:
        if tmp.exists(): tmp.unlink()
def persist(state): atomic(STATE/'transaction.json',(json.dumps(state,indent=2)+'\n').encode())
class ProbeError(RuntimeError):
    def __init__(self,s,mode,code):
        self.code=code
        self.retryable=code in ('READINESS','CONNECT','HTTP_502','HTTP_503','HTTP_504','PROBE_TIMEOUT')
        super().__init__(s+': '+mode+' '+code)

def probe(s,mode,commit='',timeout=35):
    try:
        output=run(docker('exec','-i','the-ai-crowd-'+s+'-1',PY,'-',mode,commit),input=(ROOT/'runtime_check.py').read_bytes(),timeout=timeout)
    except subprocess.TimeoutExpired:
        raise ProbeError(s,mode,'PROBE_TIMEOUT') from None
    except subprocess.CalledProcessError as exc:
        # Parse only the final controlled JSON line; never expose child stderr.
        code='PROBE_FAILED'
        try:
            record=json.loads(exc.stdout.splitlines()[-1])
            allowed={'READINESS','CONNECT','SETTINGS','REDIRECT','BUSY','PYTHON_VERSION','SQLITE_VERSION','AGENT_VERSION','AGENT_COMMIT','HONCHO_POLICY','HONCHO_CONFIG','WEBUI_HEALTH','IMPORT','INTERNAL','MODE'}
            allowed.update('HTTP_'+str(i) for i in range(100,600))
            if record.get('result')=='FAIL' and record.get('code') in allowed: code=record['code']
        except (ValueError,IndexError,TypeError,AttributeError): pass
        raise ProbeError(s,mode,code) from None
    try:
        if json.loads(output.splitlines()[-1]) != {'result':'PASS'}: raise ValueError()
    except (ValueError,IndexError,TypeError):
        raise ProbeError(s,mode,'PROBE_PROTOCOL') from None
    return output

def check_predecessor(m):
    expected=m['predecessor_transaction_sha']
    p=STACK/'state/private/backups/fleet-release-20260922/transaction.json'
    if p.is_symlink() or sha(p.read_bytes())!=expected: raise RuntimeError('Predecessor transaction drift')
    if json.loads(p.read_text()).get('phase')!='ROLLED_BACK': raise RuntimeError('Predecessor not rolled back')

def verify_topology(old,new):
    a=json.loads(json.dumps(old)); b=json.loads(json.dumps(new))
    if set(a['services']) != set(ORDER) or set(b['services']) != set(ORDER): raise RuntimeError('Unexpected service set')
    for s in ORDER:
        a['services'][s].pop('image',None); b['services'][s].pop('image',None)
    if a!=b: raise RuntimeError('Candidate changes more than image selectors')

def verify_package(m):
    for name,digest in m['files'].items():
        relative=pathlib.PurePosixPath(name)
        if relative.is_absolute() or '..' in relative.parts: raise RuntimeError('Invalid package path')
        p=ROOT/name
        if p.is_symlink() or sha(p.read_bytes())!=digest: raise RuntimeError('Package drift: '+name)

def check(m,idle=False):
    if os.geteuid()!=0 or socket.gethostname()!='MEDIA': raise RuntimeError('Run as root@media.lan')
    verify_package(m)
    check_predecessor(m)
    if sha(COMPOSE.read_bytes())!=m['compose_before_sha']: raise RuntimeError('Compose baseline drift')
    if run(git('rev-parse','HEAD')).decode().strip()!=m['stack_head']: raise RuntimeError('Stack HEAD drift')
    if run(git('status','--porcelain')).strip(): raise RuntimeError('Stack worktree must be clean')
    if (STACK/'ops/releases/20260922-r2').exists(): raise RuntimeError('Canonical release directory already exists; reconcile first')
    old=json.loads(run(compose(COMPOSE,'config','--format','json')))
    new=json.loads(run(compose(ROOT/'compose.candidate.yaml','config','--format','json')))
    verify_topology(old,new)
    run(git('var','GIT_AUTHOR_IDENT')); run(git('var','GIT_COMMITTER_IDENT'))
    for s in ORDER:
        x=m['services'][s]; d=inspect(s)
        if d['Image']!=x['base_image']: raise RuntimeError(s+': live image drift')
        if d['Config']['Labels'].get('com.docker.compose.project')!='the-ai-crowd': raise RuntimeError('Wrong project')
        if d['Config']['Labels'].get('com.docker.compose.service')!=s: raise RuntimeError('Wrong service')
        mounts=sorted((v['Source'],v['Destination'],v['RW']) for v in d['Mounts'])
        expected=sorted((v['Source'],v['Destination'],v['RW']) for v in x['mounts'])
        if mounts!=expected: raise RuntimeError(s+': mount drift')
        if not d['State']['Running'] or d['State'].get('Health',{}).get('Status')!='healthy': raise RuntimeError(s+': baseline unhealthy')
        for k in ('base_image','image'):
            if json.loads(run(docker('image','inspect',x[k])))[0]['Id']!=x[k]: raise RuntimeError('Image mismatch')
        if old['services'][s]['image']!=x['base_image'] or new['services'][s]['image']!=x['image']: raise RuntimeError('Compose/image mismatch')
        cfg=pathlib.Path(x['home'])/'config.yaml'
        if cfg.is_symlink() or sha(cfg.read_bytes())!=x['config_sha']: raise RuntimeError(s+': config drift')
        probe(s,'idle' if idle else 'health')
        print(s+': baseline e saúde autenticada OK'+(' | ocioso' if idle else ''),flush=True)
    return True

def container(m,s,helper,op,rw=False):
    args=docker('run','--rm','--network','none','--user','99:100','--read-only','--tmpfs','/tmp:rw,size=4g,mode=1777','--tmpfs','/opt/data:rw,uid=99,gid=100,mode=700',
        '--mount','type=bind,src='+str(ROOT)+',dst=/package,readonly',
        '--mount','type=bind,src='+m['services'][s]['home']+',dst=/home'+('' if rw else ',readonly'),
        '-e','HERMES_HOME=/opt/data','--entrypoint',PY,m['services'][s]['base_image'],'/package/'+helper,op)
    return args

def pipeline(commands,source=None,dest=None):
    procs=[]; previous=source; errors=[]
    try:
        for i,cmd in enumerate(commands):
            err=__import__('tempfile').TemporaryFile(); errors.append(err)
            p=subprocess.Popen(cmd,stdin=previous,stdout=dest if i==len(commands)-1 else subprocess.PIPE,stderr=err)
            if previous is not None and previous is not source: previous.close()
            procs.append(p); previous=p.stdout
        codes=[p.wait(timeout=600) for p in procs]
        if any(codes):
            diagnostics=[]
            for err in errors:
                err.seek(0); diagnostics.append(err.read().decode(errors='replace')[-1500:])
            raise RuntimeError('Backup pipeline failed; exit codes '+str(codes)+'; '+repr(diagnostics))
    finally:
        for p in procs:
            if p.poll() is None: p.kill(); p.wait()
        for f in errors: f.close()

def snapshot(m,s,suffix):
    key=STATE/'backup.key'
    if not key.exists(): atomic(key,os.urandom(32))
    crypto=docker('run','--rm','-i','--network','none','--read-only','--mount','type=bind,src='+str(ROOT)+',dst=/package,readonly',
                  '--mount','type=bind,src='+str(key)+',dst=/key,readonly','--entrypoint',PY,m['services'][s]['base_image'],'/package/backup_stream.py')
    path=STATE/(s+'-'+suffix+'.tar.gcm')
    with path.open('xb') as out:
        pipeline([container(m,s,'state_helper.py','snapshot',rw=True),crypto+['encrypt','/key']],dest=out)
        out.flush(); os.fsync(out.fileno())
    verify=container(m,s,'state_helper.py','verify-snapshot'); verify.insert(verify.index('--rm')+1,'-i')
    with path.open('rb') as source, (STATE/(s+'-'+suffix+'-verify.json')).open('xb') as out:
        pipeline([crypto+['decrypt','/key'],verify],source=source,dest=out)

def healthy(s,image,timeout=600,commit=''):
    deadline=time.monotonic()+timeout
    last='DOCKER_STARTING'
    while time.monotonic()<deadline:
        d=inspect(s)
        if d['Image']!=image: raise RuntimeError(s+': unexpected running image')
        if d['RestartCount']!=0: raise RuntimeError(s+': restart loop')
        if d['State'].get('Status') in ('dead','exited'): raise RuntimeError(s+': container stopped')
        if d['State'].get('Health',{}).get('Status')=='healthy' and d['State']['Running']:
            remaining=deadline-time.monotonic()
            if remaining<=0: break
            try:
                probe(s,'verify' if commit else 'health',commit,timeout=min(35,remaining))
                return
            except ProbeError as exc:
                if not exc.retryable: raise
                last=exc.code
        print(s+': aguardando prontidão | '+last,flush=True)
        time.sleep(min(5,max(0,deadline-time.monotonic())))
    raise RuntimeError(s+': readiness timeout; last='+last)

def restore_compose(m,state):
    if COMPOSE.read_bytes()==(STATE/'compose.before.yaml').read_bytes(): return
    if sha(COMPOSE.read_bytes())!=m['files']['compose.candidate.yaml']: raise RuntimeError('Compose changed externally; refusing rollback overwrite')
    atomic(COMPOSE,(STATE/'compose.before.yaml').read_bytes(),0o644)
    run(git('add','--','compose.yaml')); run(git('commit','-m','rollback: fleet release 20260922-r2 image selectors'))

def rollback(m,state):
    state['phase']='ROLLING_BACK'; persist(state)
    for s in state['attempted']:
        if current_image(s) not in (None,m['services'][s]['image'],m['services'][s]['base_image']):
            raise RuntimeError(s+': third-party image drift; rollback refused')
    restore_compose(m,state)
    for s in reversed(state['attempted']):
        # Preserve accepted writes. No stale database or config restore is performed.
        if current_image(s) not in (None,m['services'][s]['image'],m['services'][s]['base_image']):
            raise RuntimeError(s+': third-party image drift; rollback refused')
        snapshot(m,s,'rollback-'+str(time.time_ns()))
        run(compose(COMPOSE,'up','-d','--no-deps','--no-build','--pull','never','--force-recreate',s),timeout=240)
        healthy(s,m['services'][s]['base_image'])
    state['phase']='ROLLED_BACK'; persist(state)

def install_source(m):
    destination=STACK/'ops/releases/20260922-r2'
    if destination.exists(): raise RuntimeError('Release source already exists')
    stage=destination.with_name('20260922-r2.staging')
    stage.mkdir(mode=0o755)
    for name in [*m['files'],'release.json','review.json']:
        relative=pathlib.PurePosixPath(name)
        if relative.is_absolute() or '..' in relative.parts: raise ValueError('Invalid source path')
        target=stage/name; target.parent.mkdir(parents=True,exist_ok=True)
        data=(ROOT/name).read_bytes()
        if name in m['files'] and sha(data)!=m['files'][name]: raise RuntimeError('Source changed')
        atomic(target,data,0o644)
    os.rename(stage,destination)

def apply(m):
    check(m,idle=True)
    review=json.loads((ROOT/'review.json').read_text())
    if review.get('verdict')!='APPROVED WITHOUT CHANGES' or review.get('manifest_sha')!=sha((ROOT/'release.json').read_bytes()):
        raise RuntimeError('Independent review not released for this package')
    if STATE.exists(): raise RuntimeError('Existing transaction: inspect/recover it, never overwrite')
    STATE.mkdir(mode=0o700,parents=True)
    state={'phase':'SNAPSHOTTING','attempted':[],'services':ORDER,'manifest_sha':sha((ROOT/'release.json').read_bytes())}
    persist(state); atomic(STATE/'compose.before.yaml',COMPOSE.read_bytes())
    for s in ORDER:
        print(s+': criando e verificando backup cifrado...',flush=True)
        snapshot(m,s,'before')
        print(s+': backup verificado',flush=True)
    check(m,idle=True)
    try:
        state['phase']='APPLYING'; persist(state)
        install_source(m)
        atomic(COMPOSE,(ROOT/'compose.candidate.yaml').read_bytes(),0o644)
        run(git('add','--','compose.yaml','ops/releases/20260922-r2')); run(git('commit','-m','release: Agent 0.21.4 and WebUI approval repair'))
        for s in ORDER:
            probe(s,'idle')
            cmd=container(m,s,'state_helper.py','configure',rw=True)+[m['services'][s]['config_sha']]
            out=run(cmd,timeout=40); state.setdefault('config_receipts',{})[s]=json.loads(out)
            state['attempted'].append(s); persist(state)
            print(s+': atualizando imagem...',flush=True)
            run(compose(COMPOSE,'up','-d','--no-deps','--no-build','--pull','never','--force-recreate',s),timeout=240)
            print(s+': aguardando saúde e verificando versão...',flush=True)
            healthy(s,m['services'][s]['image'],commit=m['services'][s]['agent_commit'])
            print(s+': verified',flush=True)
        state['phase']='SUCCEEDED'; persist(state)
    except BaseException as exc:
        state['failure_code']=exc.code if isinstance(exc,ProbeError) else type(exc).__name__
        persist(state)
        print('Falha na atualização; iniciando rollback. '+str(exc)[:300],flush=True)
        try: rollback(m,state)
        except BaseException:
            state['phase']='ROLLBACK_FAILED'; persist(state)
            raise
        raise

def main():
    def interrupted(signum,frame): raise InterruptedError('Operator interrupted transaction')
    signal.signal(signal.SIGTERM,interrupted)
    p=argparse.ArgumentParser(); p.add_argument('mode',choices=['check','apply','status','recover']); a=p.parse_args()
    m=json.loads((ROOT/'release.json').read_text())
    if os.geteuid()!=0 or socket.gethostname()!='MEDIA': raise RuntimeError('Run as root on MEDIA')
    fd=os.open('/run/lock/the-ai-crowd-release.lock',os.O_CREAT|os.O_RDWR,0o600)
    fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
    if a.mode=='check': check(m); print('PRECHECK PASS; no production changes')
    elif a.mode=='status': print((STATE/'transaction.json').read_text() if STATE.exists() else 'NOT_APPLIED')
    elif a.mode=='apply': apply(m)
    else:
        verify_package(m)
        state=json.loads((STATE/'transaction.json').read_text())
        if state['manifest_sha']!=sha((ROOT/'release.json').read_bytes()): raise RuntimeError('Recovery manifest drift')
        if state['phase'] in ('SUCCEEDED','ROLLED_BACK'): raise RuntimeError('Already terminal; do not replay')
        rollback(m,state)

if __name__=='__main__':
    try: main()
    except BaseException as exc:
        # Do not dump provider env/Compose render or unredacted command stderr.
        print('FAILED: '+type(exc).__name__+': '+str(exc)[:800],file=sys.stderr)
        sys.exit(1)
