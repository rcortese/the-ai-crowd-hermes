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
    validate_origins(inventory(client), RECONCILED_EMPTY)
    peers={x['id'] for x in items(client,ROOT+'/peers/list')}
    if peers!={'Moss','Rodolfo'}: raise ValueError('Workspace peers drifted')
    print('baseline_identity_and_preserved_workspace_PASS')


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


def inventory(client):
    """Read-only evidence; connection or an empty session is never acceptance."""
    import re
    result = []
    for s in items(client, ROOT + '/sessions/list'):
        sid = s['id']
        match = re.fullmatch(r'moss-(webui|telegram)-[a-f0-9]{32}', sid)
        messages = items(client, ROOT + '/sessions/' + sid + '/messages/list')
        result.append({'id': sid, 'created_at': s.get('created_at'),
                       'surface': match.group(1) if match else None,
                       'message_count': len(messages),
                       'authors': sorted({m['peer_id'] for m in messages})})
    return result


# Exact empty diagnostic row inspected read-only on MEDIA; never ingestion credit.
RECONCILED_EMPTY = {'private': '2026-09-22T18:41:36.690462Z'}


def validate_origins(rows, reconciled_empty):
    for row in rows:
        if row['surface']:
            if set(row['authors']) - {'Moss', 'Rodolfo'}:
                raise ValueError('Unexpected author in recovery workspace')
        elif not (row['message_count'] == 0 and row['id'] in reconciled_empty
                  and row['created_at'] == reconciled_empty[row['id']]):
            raise ValueError('Unreconciled session: ' + json.dumps(row, sort_keys=True))
    print('preserved_workspace_origins_PASS')


def channels(client, reconciled_empty=None, since=None):
    # Direct callers must opt in to exceptions; CLI uses the reviewed constant.
    reconciled_empty = reconciled_empty or {}
    rows = inventory(client)
    validate_origins(rows, reconciled_empty)
    surfaces = set()
    fresh_counts = {'webui': 0, 'telegram': 0}
    for row in rows:
        sid = row['id']
        if not row['surface']:
            if (row['message_count'] == 0 and sid in reconciled_empty
                    and row['created_at'] == reconciled_empty[sid]):
                continue
            raise ValueError('Unreconciled session: ' + json.dumps(row, sort_keys=True))
        peers = set(row['authors'])
        if peers - {'Moss', 'Rodolfo'}:
            raise ValueError('Unexpected author in fresh workspace')
        if {'Moss', 'Rodolfo'} <= peers:
            surfaces.add(row['surface'])
            if since:
                from datetime import datetime
                if datetime.fromisoformat(row['created_at']) >= datetime.fromisoformat(since):
                    fresh_counts[row['surface']] += 1
    if surfaces != {'webui', 'telegram'}:
        raise ValueError('Channel ingestion incomplete; observed=' + ','.join(sorted(surfaces)))
    if since and any(n < 2 for n in fresh_counts.values()):
        raise ValueError('Need two NEW conversations per channel (write and recall): ' + json.dumps(fresh_counts))
    print('both_channels_ingestion_readback_PASS; cross_session_recall_NOT_VERIFIED')


def dreaming(client, enabled=True):
    if enabled:
        channels(client, RECONCILED_EMPTY)
    w=workspace(client)
    config=w['configuration']
    config['dream']={**config.get('dream',{}),'enabled':enabled}
    call(client,'PUT',ROOT,{'configuration':config})
    if workspace(client)['configuration']['dream']['enabled'] is not enabled:
        raise ValueError('Dream activation readback failed')
    print('native_dreaming_readback_PASS enabled=' + str(enabled))


if __name__=='__main__':
    p=argparse.ArgumentParser()
    p.add_argument('operation',choices=['baseline','installed','idle','channels','dream','undream','configured','inventory'])
    p.add_argument('--reconciled-empty', type=Path, help='Reviewed exact empty-session ID/creation-time map; channels only')
    p.add_argument('--since', help='Require two new conversations per channel after this ISO timestamp')
    args=p.parse_args()
    if args.reconciled_empty and args.operation != 'channels':
        p.error('--reconciled-empty is only valid with channels')
    if args.operation=='installed': installed()
    elif args.operation=='idle': idle()
    else:
        with httpx.Client(base_url=URL,timeout=30,follow_redirects=False,trust_env=False) as client:
            if args.operation == 'inventory':
                print(json.dumps({'sessions': inventory(client), 'cross_session_recall': 'NOT_VERIFIED'}, indent=2))
            elif args.operation == 'channels':
                reconciled = json.loads(args.reconciled_empty.read_text()) if args.reconciled_empty else RECONCILED_EMPTY
                channels(client, reconciled, args.since)
            else:
                {'baseline':baseline,'dream':dreaming,'undream':lambda c: dreaming(c, False),'configured':configured}[args.operation](client)
