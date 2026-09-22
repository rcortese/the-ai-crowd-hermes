"""Runtime checks and workspace activation; no conversation content printed."""
import argparse
import hashlib
import json
import os
import time
from pathlib import Path
import httpx

URL='http://honcho-api:8000'
ROOT='/v3/workspaces/moss-rodolfo'


def call(client,method,path,payload=None):
    r=client.request(method,path,json=payload)
    r.raise_for_status()
    return r.json() if r.content else None


def items(client,path):
    result=[]
    for page in range(1,101):
        data=call(client,'POST',path+f'?page={page}&size=100',{})
        result.extend(data['items'])
        if len(result)>=data['total']:
            if len(result)!=data['total']: raise ValueError('Pagination inconsistency')
            return result
    raise ValueError('Inventory limit exceeded')


def workspace(client):
    workspaces=items(client,'/v3/workspaces/list')
    found=[x for x in workspaces if x['id']=='moss-rodolfo']
    if len(found)!=1: raise ValueError('Fresh workspace missing or ambiguous')
    if any(x['id']=='hermes_moss' for x in workspaces): raise ValueError('Exclusive legacy workspace has returned')
    return found[0]


def webui_runs():
    # Use the same effective config, opt-in and capability gates as the WebUI.
    import sys
    if '/opt/hermes-webui' not in sys.path:
        sys.path.insert(0, '/opt/hermes-webui')
    from hermes_cli.config import load_config
    from api.gateway_chat import _gateway_use_runs_api_enabled, _gateway_base_url, _gateway_api_key
    from api.config import gateway_supports_approval
    cfg = load_config()
    base = _gateway_base_url(cfg)
    if base not in ('http://moss:8648', 'http://127.0.0.1:8648', 'http://localhost:8648'):
        raise ValueError('WebUI gateway is not the verified local Moss target')
    if not _gateway_use_runs_api_enabled(cfg):
        raise ValueError('WebUI Runs API opt-in is disabled')
    if not gateway_supports_approval(base, _gateway_api_key()):
        raise ValueError('WebUI Runs capability is unavailable')
    print('webui_effective_runs_route_and_capability_PASS')


def baseline(client):
    webui_runs()
    if os.environ.get('AGENT_NAME')!='moss': raise ValueError('Wrong container persona')
    for p in ('/opt/data/honcho.json','/opt/data/moss-memory-policy.json','/opt/data/moss-memory-gate.key'):
        if Path(p).exists(): raise ValueError('Configuration already exists; reconcile instead of overwrite')
    approved=json.loads(Path('/opt/data/profiles/moss/platforms/pairing/telegram-approved.json').read_text())
    if not isinstance(approved,dict) or len(approved)!=1 or not next(iter(approved)).isdecimal():
        raise ValueError('Telegram owner not unambiguously paired')
    owner=next(iter(approved))
    if not os.environ.get('TELEGRAM_BOT_TOKEN') or owner not in [x.strip() for x in os.environ.get('TELEGRAM_ALLOWED_USERS','').split(',')]:
        raise ValueError('Live gateway Telegram token/owner allowlist not configured')
    if not os.environ.get('HERMES_WEBUI_PASSWORD'): raise ValueError('WebUI password auth not present')
    if os.environ.get('HERMES_WEBUI_CHAT_BACKEND')!='gateway': raise ValueError('WebUI is not API-backed')
    w=workspace(client)
    if w['configuration'].get('dream',{}).get('enabled') is not False: raise ValueError('Dreaming already active')
    if items(client,ROOT+'/sessions/list'): raise ValueError('Workspace is not empty')
    peers={x['id'] for x in items(client,ROOT+'/peers/list')}
    if peers!={'Moss','Rodolfo'}: raise ValueError('Workspace peers drifted')
    print('baseline_identity_and_empty_workspace_PASS')


def installed():
    webui_runs()
    from agent.moss_memory_gate import policy,_key
    p=policy()
    if not p or len(_key())!=32: raise ValueError('Memory gate missing')
    from plugins.memory.honcho.client import HonchoClientConfig
    c=HonchoClientConfig.from_global_config()
    if c.workspace_id!='moss-rodolfo' or c.peer_name!='Rodolfo' or c.ai_peer!='Moss' or c.a2a_sessions or c.session_strategy!='per-session':
        raise ValueError('Effective Honcho identity/behavior mismatch')
    import inspect
    import plugins.memory.honcho as provider
    import gateway.platforms.api_server as api
    if 'moss_memory_gate' not in inspect.getsource(provider.HonchoMemoryProvider.initialize):
        raise ValueError('Provider gate missing')
    if 'request_admission' not in inspect.getsource(api.APIServerAdapter._make_profile_prefix_middleware):
        raise ValueError('API admission missing')
    print('installed_gate_and_effective_config_PASS')


def idle():
    key=os.environ.get('API_SERVER_KEY')
    if not key: raise ValueError('Missing local API authorization for idle check')
    with httpx.Client(timeout=10,trust_env=False,follow_redirects=False) as client:
        r=client.get('http://127.0.0.1:8648/health/detailed',headers={'Authorization':'Bearer '+key})
        r.raise_for_status()
        d=r.json()
    if d.get('gateway_busy') or d.get('active_agents') != 0:
        raise ValueError('Gateway still busy; finish active work before apply')
    readiness=d.get('readiness',{})
    if readiness.get('status') not in ('ready','ok'):
        raise ValueError('Gateway readiness not ready; inspect before interruption')
    queues=readiness.get('checks',{}).get('background_queues',{})
    if any(queues.get(k) != 0 for k in ('active_api_runs','process_completions','active_delegations')):
        raise ValueError('API runs, process completions or delegations still active')
    print('gateway_idle_PASS')


def configured(client):
    from hermes_cli.config import load_config
    from plugins.memory.honcho.client import HonchoClientConfig
    selected=load_config().get('memory',{}).get('provider')
    if selected not in ('honcho',['honcho']) or not HonchoClientConfig.from_global_config().enabled:
        raise ValueError('Honcho is not the active configured provider')
    if workspace(client)['configuration'].get('dream',{}).get('enabled') is not True:
        raise ValueError('Native dreaming is not enabled')
    print('active_provider_and_native_dreaming_readback_PASS')


def channels(client):
    sessions=items(client,ROOT+'/sessions/list')
    surfaces=set()
    for s in sessions:
        sid=s['id']
        prefix=next((x for x in ('webui','telegram') if sid.startswith('moss-'+x+'-')),None)
        if not prefix: raise ValueError('Unexpected session source in fresh workspace')
        messages=items(client,ROOT+'/sessions/'+sid+'/messages/list')
        peers={m['peer_id'] for m in messages}
        if peers-{'Moss','Rodolfo'}: raise ValueError('Unexpected author in fresh workspace')
        if {'Moss','Rodolfo'}<=peers: surfaces.add(prefix)
    if surfaces!={'webui','telegram'}: raise ValueError('Both human channels are not yet verified')
    print('both_channels_ingestion_readback_PASS')


def dreaming(client):
    channels(client)
    w=workspace(client)
    config=w['configuration']
    config['dream']={**config.get('dream',{}),'enabled':True}
    call(client,'PUT',ROOT,{'configuration':config})
    if workspace(client)['configuration']['dream']['enabled'] is not True:
        raise ValueError('Dream activation readback failed')
    print('native_dreaming_enabled_readback_PASS')


if __name__=='__main__':
    p=argparse.ArgumentParser()
    p.add_argument('operation',choices=['baseline','installed','idle','channels','dream','configured'])
    args=p.parse_args()
    if args.operation=='installed': installed()
    elif args.operation=='idle': idle()
    else:
        with httpx.Client(base_url=URL,timeout=30,follow_redirects=False,trust_env=False) as client:
            {'baseline':baseline,'channels':channels,'dream':dreaming,'configured':configured}[args.operation](client)
