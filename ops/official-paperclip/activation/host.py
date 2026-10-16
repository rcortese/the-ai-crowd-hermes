"""Host MEDIA backend; fixed Moss paths/argv, existing native marker only.
No imports from materialized old migration packages. No generic command payloads.
"""
import base64
import copy
from datetime import datetime

import json
import os
from pathlib import Path
import re

import time

from common import command, digest, encoded, need, secure, sha

ROOT = Path('/mnt/user/appdata/the-ai-crowd')
PRIVATE = ROOT / 'deployment-private/moss/tac246-activation'
HOME = ROOT / 'moss/home/profiles/moss'
CONFIG = HOME / 'config.yaml'
OVERRIDE = ROOT / 'deployment-private/moss/moss-image.override.json'
COMPOSE = ROOT / 'compose.yaml'
CONTAINER = 'the-ai-crowd-moss-1'
PYTHON = '/opt/hermes/.venv/bin/python'
CANDIDATE = 'sha256:4e5d39b682ff055b847ca16f9658f9b34415b708c0d38ab500930c1c3c83f51c'
PREIMAGE = 'sha256:e5dc456e2eca82a2f955506abba9f90d19c9280cdbfa56d4fff163c2439cccad'
SIBLINGS = ('denholm', 'jen', 'richmond')
COMPOSE_ARGV = ['/usr/bin/docker', 'compose', '--project-directory', str(ROOT),
                '-f', str(COMPOSE), '-f', str(OVERRIDE)]

# Fixed probe, credential never leaves container environment. No /proc env scraping.
HTTP = r'''
import json,os,sys,urllib.request
p=json.load(sys.stdin)
key=os.environ.get('API_SERVER_KEY')
assert key
headers={'Authorization':'Bearer '+key}
headers.update(p.get('headers',{}))
req=urllib.request.Request('http://127.0.0.1:'+str(p.get('port',8648))+p['path'],
 data=json.dumps(p['body']).encode() if 'body' in p else None,headers=headers,method=p['method'])
class NoRedirect(urllib.request.HTTPRedirectHandler):
 def redirect_request(self,*a,**k): return None
with urllib.request.build_opener(NoRedirect).open(req,timeout=5) as r:
 raw=r.read(4*1024*1024+1)
 assert len(raw)<=4*1024*1024
 print(json.dumps(json.loads(raw)))
'''

MARKER = r'''
import hashlib,json,os,pathlib,stat,sys,tempfile
from datetime import datetime,timezone
from gateway.drain_control import current_instantiation_epoch
p=json.load(sys.stdin); home=pathlib.Path('/opt/data/profiles/moss'); target=home/'.drain_request.json'
def ident():
 s=target.lstat(); assert stat.S_ISREG(s.st_mode)
 return {'dev':s.st_dev,'ino':s.st_ino,'sha':hashlib.sha256(target.read_bytes()).hexdigest()}
if p['action']=='create':
 body={'action':'drain','requested_at':datetime.now(timezone.utc).isoformat(),
       'epoch':current_instantiation_epoch(),'principal':'tac246:'+p['run'],'suppress_notification':True}
 assert body['epoch']
 fd,name=tempfile.mkstemp(prefix='.tac246-drain-',dir=home)
 try:
  with os.fdopen(fd,'wb') as f:
   os.fchmod(f.fileno(),0o600); f.write(json.dumps(body).encode()); f.flush(); os.fsync(f.fileno())
  s=pathlib.Path(name).stat()
  receipt={'dev':s.st_dev,'ino':s.st_ino,'sha':hashlib.sha256(pathlib.Path(name).read_bytes()).hexdigest()}
  # Staged ownership receipt is returned BEFORE publication in a separate invocation.
  print(json.dumps({'owned':receipt,'stage':pathlib.Path(name).name,'requested':body['requested_at']}))
 except BaseException:
  pathlib.Path(name).unlink(missing_ok=True); raise
elif p['action']=='publish':
 stage=home/p['stage']; assert stage.name==p['stage'] and stage.name.startswith('.tac246-drain-')
 s=stage.lstat(); assert stat.S_ISREG(s.st_mode)
 assert {'dev':s.st_dev,'ino':s.st_ino,'sha':hashlib.sha256(stage.read_bytes()).hexdigest()}==p['owned']
 os.link(stage,target); stage.unlink(); print('{}')
elif p['action']=='clear':
 assert ident()==p['owned']
 target.unlink(); print('{}')
else:
 assert ident()==p['owned']; print('{}')
d=os.open(home,os.O_RDONLY|os.O_DIRECTORY); os.fsync(d); os.close(d)
'''

CONFIG_TRANSFORM = r'''
import base64,json,pathlib,sys,yaml
packet=json.load(sys.stdin); mod={'__name__':'tac246_pure_transform'}
exec(packet['transformer'],mod)
path=pathlib.Path('/opt/data/profiles/moss/config.yaml'); raw=path.read_bytes()
# Reject anchors, aliases and duplicate keys rather than normalize ambiguously.
assert not any(isinstance(t,(yaml.tokens.AliasToken,yaml.tokens.AnchorToken)) for t in yaml.scan(raw))
node=yaml.compose(raw)
def unique(n):
 if isinstance(n,yaml.nodes.MappingNode):
  keys=[k.value for k,v in n.value]; assert len(keys)==len(set(keys))
  for k,v in n.value: unique(v)
 elif isinstance(n,yaml.nodes.SequenceNode):
  for v in n.value: unique(v)
unique(node)
new=yaml.safe_dump(mod['transform'](yaml.safe_load(raw),'moss'),sort_keys=False,allow_unicode=True).encode()
print(base64.b64encode(new).decode())
'''

COMPOSE_SOURCE = r'''
import json,sys,yaml
c=yaml.safe_load(json.load(sys.stdin)['compose'])
assert 'build' not in c['services']['moss']
print('{}')
'''


def identity(c):
    return {'id': c['Id'], 'image': c['Image'], 'started': c['State']['StartedAt'],
            'restarts': c['RestartCount'], 'running': c['State']['Running']}


def invariants(c):
    # Preserve every non-image process, mount, environment and host setting.
    config = {k: v for k, v in c['Config'].items() if k not in ('Image', 'Hostname', 'Labels')}
    config['Labels'] = {k: v for k, v in (c['Config'].get('Labels') or {}).items()
                        if k not in ('com.docker.compose.config-hash', 'com.docker.compose.image')}
    config['Env'] = sorted(config.get('Env') or [])
    hc = copy.deepcopy(c['HostConfig'])
    for k in ('Binds', 'Mounts'):
        if hc.get(k):
            hc[k] = sorted(hc[k], key=lambda x: encoded(x))
    return digest({'config': config, 'host': hc,
                   'mounts': sorted(c['Mounts'], key=lambda x: x['Destination'])})


def validate_plan(p):
    def hashed(value, length=64):
        need(isinstance(value, str) and re.fullmatch('[0-9a-f]{%d}' % length, value), 'HASH_REQUIRED')

    def ident(value):
        need(set(value) == {'id','image','started','restarts','running'}, 'IDENTITY_KEYS')
        hashed(value['id'])
        need(isinstance(value['image'], str) and re.fullmatch('sha256:[0-9a-f]{64}', value['image']) and
             isinstance(value['started'], str) and bool(value['started']) and
             type(value['restarts']) is int and value['restarts'] >= 0 and value['running'] is True,
             'IDENTITY_VALUES')

    def evidence(value):
        need(set(value) == {'path','sha','uid'} and type(value['uid']) is int and value['uid'] >= 0 and
             isinstance(value['path'], str) and re.fullmatch(re.escape(str(PRIVATE / 'inputs'))+
             '/[A-Za-z0-9_-]+\\.json', value['path']), 'EVIDENCE_INPUT')
        hashed(value['sha'])

    need(set(p) == {'schema', 'scope', 'host', 'code', 'source', 'files', 'preimage',
                    'siblings', 'render', 'invariants', 'installed', 'catalog', 'continuation',
                    'timeouts', 'ingresses', 'adapter'}, 'PLAN_KEYS')
    need(p['schema'] == 1 and p['scope'] == 'tac246-moss-only' and p['host'] == 'MEDIA', 'PLAN_SCOPE')
    need(type(p['schema']) is int, 'PLAN_SCHEMA_TYPE')
    for key in ('code','render','invariants'):
        hashed(p[key])
    ident(p['preimage'])
    for value in p['siblings'].values():
        need(set(value) == {'identity','invariants'}, 'SIBLING_KEYS')
        ident(value['identity']); hashed(value['invariants'])
    evidence(p['adapter'])
    need(set(p['continuation']) == {'session','session_sha','memory_off_evidence'} and
         isinstance(p['continuation']['session'], str) and
         re.fullmatch('[A-Za-z0-9_-]{8,128}', p['continuation']['session']) and
         p['continuation']['session'] != 'df6e86989771', 'CONTINUATION_SESSION_INPUT')
    hashed(p['continuation']['session_sha']); evidence(p['continuation']['memory_off_evidence'])
    need(set(p['catalog']) == {'count','sha'} and type(p['catalog']['count']) is int and
         p['catalog']['count'] > 0, 'CATALOG_INPUT')
    hashed(p['catalog']['sha'])
    need(set(p['files']) == {'config', 'compose', 'override', 'transformer'}, 'FILE_ALLOWLIST')
    for k, path in {'config': CONFIG, 'compose': COMPOSE, 'override': OVERRIDE,
                    'transformer': PRIVATE / 'inputs/configure.py'}.items():
        entry = p['files'][k]
        need(set(entry) == {'path', 'pre', 'post', 'uid', 'mode'} and entry['path'] == str(path), 'FILE_PATH')
        need(type(entry['uid']) is int and entry['uid'] >= 0 and type(entry['mode']) is int and
             entry['mode'] in (0o600,0o640,0o644), 'FILE_CUSTODY')
        need(all(isinstance(entry[x], str) and re.fullmatch('[0-9a-f]{64}', entry[x]) for x in ('pre','post')),
             'HASH_REQUIRED')
    need(p['preimage']['image'] == PREIMAGE and set(p['siblings']) == set(SIBLINGS), 'IDENTITY_REQUIRED')
    manifest = json.loads((Path(__file__).parent / 'candidate.json').read_bytes())
    need(p['installed'] == manifest['installed'], 'CANDIDATE_MANIFEST_CAS')
    need(p['files']['compose']['pre'] == p['files']['compose']['post'] and
         p['files']['transformer']['pre'] == p['files']['transformer']['post'], 'UNSCOPED_FILE_DELTA')
    need(p['files']['transformer']['pre'] ==
         '3cc5c8930ac6894dbad28969f8786f08566a0d9833afbf3e7fa5ee2120018a33', 'TRANSFORMER_NOT_APPROVED')
    need(p['ingresses'] == ['gateway', 'api', 'webui'], 'INGRESS_ALLOWLIST')
    need(set(p['timeouts']) == {'idle', 'drain', 'child', 'interval', 'continuation'}, 'TIMEOUT_KEYS')
    need(all(type(v) in (int, float) and 0 < v <= 600 for v in p['timeouts'].values()) and
         1 <= p['timeouts']['interval'] <= 3, 'TIMEOUT_RANGE')
    need(set(p['installed']) and all(not Path(k).is_absolute() and '..' not in Path(k).parts
                                   for k in p['installed']), 'INSTALLED_PATHS')
    source = Path(p['source']['root'])
    need(set(p['source']) == {'root','commit','tree','uid','mode','paths'} and
         type(p['source']['uid']) is int and p['source']['uid'] >= 0 and
         p['source']['mode'] in (0o700,0o755), 'SOURCE_CUSTODY')
    hashed(p['source']['commit'],40); hashed(p['source']['tree'],40)
    names = ('common.py','executor.py','host.py','supervisor.py','continuation.py',
             'candidate.json','plan.schema.json','README.md','test_activation.py')
    need(source == PRIVATE / 'source' and p['source']['paths'] ==
         sorted('ops/official-paperclip/activation/'+x for x in names), 'SOURCE_ALLOWLIST')
    return p


class Host:
    now = staticmethod(time.time)
    sleep = staticmethod(time.sleep)

    def __init__(self, plan):
        self.p = validate_plan(plan)

    def external_evidence(self, entry, kind):
        need(set(entry) == {'path', 'sha', 'uid'}, 'EVIDENCE_INPUT')
        path = Path(entry['path'])
        need(path.parent == PRIVATE / 'inputs', 'EVIDENCE_LOCATION')
        secure(path, 0o600, entry['uid'])
        raw = path.read_bytes()
        need(sha(raw) == entry['sha'], 'EVIDENCE_CAS')
        evidence = json.loads(raw)
        need(evidence['kind'] == kind and evidence['state'] == 'VERIFIED' and
             0 <= self.now() - evidence['observed'] <= 300 and
             isinstance(evidence['producer'], str) and bool(evidence['producer']), 'EVIDENCE_NOT_VERIFIED')
        return evidence

    def memory_off(self, entry):
        e = self.external_evidence(entry, 'api-server-memory-off')
        need(e['platform'] == 'api_server' and e['memoryOff'] is True and
             e['containerImage'] == CANDIDATE, 'MEMORY_OFF_UNPROVEN')

    def prerequisites(self):
        # Paperclip TSX adapter is process-cached. Merely installing image layers
        # or changing Moss's pin cannot activate producer request metadata.
        e = self.external_evidence(self.p['adapter'], 'official-adapter-producer')
        need(e['image'] == 'sha256:b9ad3a9483657cf25cc345310e1ad0801d926f6e43564c7aba06b5e8bdd416aa' and
             e['reloaded'] is True and e['requestContextVerified'] is True and
             isinstance(e['processStart'], str) and bool(e['processStart']), 'ADAPTER_PRODUCER_NOT_ACTIVE')
        from continuation import preflight
        preflight(self, self.p)

    @staticmethod
    def marker_time(marker):
        return datetime.fromisoformat(marker['requested']).timestamp()

    def docker(self, *args, raw=None, timeout=30):
        return command(['/usr/bin/docker', *args], raw=raw, timeout=timeout)

    def probe(self, script, packet, timeout=30):
        return self.docker('exec', '-i', CONTAINER, PYTHON, '-B', '-c', script,
                           raw=encoded(packet), timeout=timeout)

    def http(self, method, path, body=None, headers=None, port=8648):
        need(method in ('GET', 'POST'), 'HTTP_METHOD')
        packet = {'method': method, 'path': path, 'headers': headers or {}, 'port': port}
        if body is not None:
            packet['body'] = body
        return json.loads(self.probe(HTTP, packet))

    def snapshot(self):
        w = self.http('GET', '/health?deep=1', port=8787)
        d = self.http('GET', '/health/detailed')
        need(w['status'] == 'ok' and d['status'] == 'ok', 'HEALTH_NOT_READY')
        q = d['readiness']['checks']['background_queues']
        return {'observed': self.now(), 'updated': datetime.fromisoformat(d['updated_at']).timestamp(),
                'state': d['gateway_state'], 'counters': {
                    'webui_runs': w['active_runs'], 'webui_streams': w['active_streams'],
                    'api_runs': d['api_server']['active_runs'], 'background_api': q['active_api_runs'],
                    'completions': q['process_completions'], 'delegations': q['active_delegations'],
                    'agents': d['active_agents']}}

    def admission(self):
        # Existing marker gates the gateway/API, not an independently executing
        # WebUI owner. No installed native endpoint proves closure of that owner.
        # This explicit capability gap must precede marker/config/lifecycle effects.
        for ingress in self.p['ingresses']:
            need(ingress in ('gateway', 'api'), 'BLOCKED_WEBUI_ADMISSION_ACCOUNTING')

    def marker(self, action, packet):
        return json.loads(self.probe(MARKER, dict(packet, action=action)))

    def inspect(self, role='moss'):
        return json.loads(self.docker('inspect', 'the-ai-crowd-'+role+'-1'))[0]

    def file_check(self, key, after=False):
        e = self.p['files'][key]
        f = secure(e['path'], e['mode'], e['uid'])
        need(sha(f.read_bytes()) == e['post' if after else 'pre'], 'FILE_CAS_'+key.upper())
        return f

    def source_check(self):
        s = self.p['source']; root = secure(s['root'], s['mode'], s['uid'], True)
        argv = ['/usr/bin/git', '-c', 'safe.directory='+str(root), '-C', str(root)]
        need(command(argv+['rev-parse', 'HEAD']).decode().strip() == s['commit'], 'SOURCE_HEAD')
        need(command(argv+['rev-parse', 'HEAD^{tree}']).decode().strip() == s['tree'], 'SOURCE_TREE')
        need(not command(argv+['status', '--porcelain', '--untracked-files=all', '--', *s['paths']]),
             'SOURCE_DIRTY')
        for path in s['paths']:
            secure(root / path)
            need(command(argv+['show', 'HEAD:'+path]) == (root / path).read_bytes(), 'SOURCE_BYTES')

    def render(self):
        return json.loads(command(COMPOSE_ARGV + ['config', '--format', 'json']))

    def cas(self, phase):
        need(phase == 'pre', 'CAS_PHASE')
        self.source_check()
        for k in self.p['files']:
            self.file_check(k)
        c = self.inspect()
        need(identity(c) == self.p['preimage'] and invariants(c) == self.p['invariants'], 'CONTAINER_CAS')
        image = json.loads(self.docker('image', 'inspect', CANDIDATE))[0]
        need(image['Id'] == CANDIDATE, 'CANDIDATE_NOT_LOCAL')
        for role in SIBLINGS:
            sibling = self.inspect(role)
            need({'identity': identity(sibling), 'invariants': invariants(sibling)} == self.p['siblings'][role],
                 'SIBLING_CAS')
        render = self.render()
        need(digest(render) == self.p['render'], 'COMPOSE_RENDER_CAS')
        need('build' not in render['services']['moss'], 'RUNTIME_BUILD_FORBIDDEN')
        self.probe(COMPOSE_SOURCE, {'compose': self.file_check('compose').read_text()})
        service = render['services']['moss']; ic = image['Config']
        future_env = dict(x.split('=',1) for x in ic.get('Env',[]))
        for k,v in service.get('environment',{}).items():
            if v is None: future_env.pop(k,None)
            else: future_env[k] = v
        need(sorted(k+'='+v for k,v in future_env.items()) == sorted(c['Config']['Env']),
             'CANDIDATE_ENV_DRIFT')
        for key, override in (('User','user'),('Entrypoint','entrypoint'),('Cmd','command'),('WorkingDir','working_dir')):
            need(service.get(override,ic.get(key)) == c['Config'].get(key), 'CANDIDATE_PROCESS_DRIFT')
        self._render_pre = render
        return {'identity': identity(c), 'invariants': invariants(c), 'render': digest(render)}

    def config_bytes(self):
        transformer = self.file_check('transformer').read_text()
        new = base64.b64decode(self.probe(CONFIG_TRANSFORM, {'transformer': transformer}), validate=False)
        need(sha(new) == self.p['files']['config']['post'], 'CONFIG_DERIVATION')
        return new

    def write_config(self, content):
        path = self.file_check('config'); old = path.read_bytes(); st = path.stat()
        with path.open('r+b') as f:
            need(f.read() == old and os.fstat(f.fileno()).st_ino == st.st_ino, 'CONFIG_WRITE_CAS')
            f.seek(0); f.write(content); f.truncate(); f.flush(); os.fsync(f.fileno())
        self.file_check('config', True)

    def write_override(self):
        path = self.file_check('override'); old = path.read_bytes()
        obj = json.loads(old)
        need(set(obj) == {'services'} and set(obj['services']) == {'moss'} and
             set(obj['services']['moss']) == {'image'}, 'OVERRIDE_SCOPE')
        obj['services']['moss']['image'] = CANDIDATE
        new = encoded(obj) + b'\n'
        need(sha(new) == self.p['files']['override']['post'], 'OVERRIDE_DERIVATION')
        # Preserve owner/mode; this is an explicitly bounded in-place write.
        with path.open('r+b') as f:
            need(f.read() == old, 'OVERRIDE_WRITE_CAS')
            f.seek(0); f.write(new); f.truncate(); f.flush(); os.fsync(f.fileno())
        self.file_check('override', True)

    def recreate(self):
        self.source_check()
        for k in self.p['files']:
            self.file_check(k, True)
        expected = copy.deepcopy(self._render_pre)
        expected['services']['moss']['image'] = CANDIDATE
        need(self.render() == expected, 'POST_CONFIG_RENDER_DRIFT')
        command(COMPOSE_ARGV + ['up', '-d', '--no-build', '--no-deps', '--pull', 'never', 'moss'], timeout=120)

    def verify(self):
        # Successor ID/start may change. Everything except image identity must not.
        c = self.inspect()
        need(c['Image'] == CANDIDATE and c['State']['Running'] and invariants(c) == self.p['invariants'],
             'SUCCESSOR_INVARIANTS')
        deadline = self.now() + 150
        while True:
            try:
                s = self.snapshot()
                ready = (s['state'] == 'running' and 0 <= self.now()-s['updated'] <= 5 and
                         all(type(v) is int and v >= 0 for v in s['counters'].values()))
            except Exception:
                ready = False
            if ready:
                break
            need(self.now() < deadline, 'SUCCESSOR_HEALTH_TIMEOUT')
            self.sleep(1)
        for k in self.p['files']:
            self.file_check(k, True)
        self.source_check()
        expected = copy.deepcopy(self._render_pre)
        expected['services']['moss']['image'] = CANDIDATE
        need(self.render() == expected, 'SUCCESSOR_RENDER_DRIFT')
        for role in SIBLINGS:
            s = self.inspect(role)
            need({'identity': identity(s), 'invariants': invariants(s)} == self.p['siblings'][role],
                 'SIBLING_POST_CAS')
        packet = {'installed': self.p['installed'], 'catalog': self.p['catalog']}
        app = json.loads(self.probe(APP_VERIFY, packet, timeout=60))
        need(app == {'bytes': True, 'context': True, 'bridgeInactive': True, 'catalog': True},
             'APPLICATION_NOT_VERIFIED')
        return {'successor': identity(c), 'application': app}


APP_VERIFY = r'''
import asyncio,hashlib,json,os,pathlib,sys,yaml
from mcp import ClientSession,StdioServerParameters
from mcp.client.stdio import stdio_client
p=json.load(sys.stdin); home=pathlib.Path('/opt/data/profiles/moss')
assert os.environ['HERMES_HOME']==str(home)
for name,value in p['installed'].items():
 assert hashlib.sha256((pathlib.Path('/opt/hermes')/name).read_bytes()).hexdigest()==value
cfg=yaml.safe_load((home/'config.yaml').read_text()); server=cfg['mcp_servers']['paperclip']
assert server['command']=='/opt/paperclip-mcp/node_modules/.bin/paperclip-mcp-server'
assert server.get('args',[])==[] and not server.get('tools',{}).get('include') and not server.get('tools',{}).get('exclude')
env=server['env']; assert env['PAPERCLIP_AGENT_ID']=='541d5e6d-2ba6-42ee-81b0-a5ab2d892a10'
assert env['PAPERCLIP_COMPANY_ID']=='9d914ba2-725e-4006-81f8-bc6f1eb1f411'
assert env['PAPERCLIP_RUN_CONTEXT_MODE']=='request' and 'PAPERCLIP_RUN_ID' not in env
legacy={'paperclip_access','paperclip-access','tac_paperclip_callback','tac-paperclip-callback','denholm_ceo','denholm-ceo'}
assert not legacy.intersection(cfg.get('plugins',{}).get('enabled',[]))
assert legacy.issubset(cfg.get('plugins',{}).get('disabled',[]))
assert all(not legacy.intersection(v) for v in cfg.get('platform_toolsets',{}).values())
assert 'paperclip' in cfg['platform_toolsets']['api_server']
async def main():
 with open(os.devnull,'w') as err:
  async with stdio_client(StdioServerParameters(command=server['command'],args=[],env=env),errlog=err) as (r,w):
   async with ClientSession(r,w) as session:
    init=await session.initialize(); assert init.serverInfo.name=='paperclip'
    tools=[]; cursor=None; seen=set()
    while True:
     page=await session.list_tools(cursor=cursor)
     names=[t.name for t in page.tools]
     assert names and all(isinstance(n,str) and n for n in names)
     tools.extend(names)
     cursor=page.nextCursor
     if cursor is None: break
     assert isinstance(cursor,str) and cursor and cursor not in seen
     seen.add(cursor)
    assert len(tools)==len(set(tools))
    canonical=json.dumps(sorted(tools),sort_keys=True,separators=(',',':')).encode()
    assert len(tools)==p['catalog']['count'] and hashlib.sha256(canonical).hexdigest()==p['catalog']['sha']
    result=await session.call_tool('paperclipMe',{})
    assert result.isError and 'Missing paperclip/run-context' in str(result)
asyncio.run(asyncio.wait_for(main(),timeout=45))
print(json.dumps({'bytes':True,'context':True,'bridgeInactive':True,'catalog':True}))
'''
