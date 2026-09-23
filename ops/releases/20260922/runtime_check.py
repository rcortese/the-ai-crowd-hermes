"""Credential-safe in-container gates. No model calls or external writes."""
import json, os, sys, pathlib, urllib.request

def api_settings():
    # Gateway startup gives its own home .env precedence over stale container
    # exports. Read only the two probe inputs; never hydrate/mutate runtime files.
    from dotenv import dotenv_values
    home=pathlib.Path(os.environ.get('HERMES_HOME','/opt/data'))
    values=dotenv_values(home/'.env') if (home/'.env').exists() else {}
    def setting(name):
        value=values[name] if name in values else os.environ.get(name)
        if not value: raise RuntimeError('Missing probe setting: '+name)
        return value
    return setting('API_SERVER_PORT'),setting('API_SERVER_KEY')

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self,*args,**kwargs):
        raise RuntimeError('Health redirect refused')

def get(path):
    port,key=api_settings()
    if not port.isdecimal() or not 1 <= int(port) <= 65535:
        raise RuntimeError('Invalid API probe port')
    req=urllib.request.Request('http://127.0.0.1:'+port+path,headers={'Authorization':'Bearer '+key})
    with urllib.request.build_opener(urllib.request.ProxyHandler({}),NoRedirect()).open(req,timeout=10) as r:
        return json.load(r)

def check_idle(d):
    if d.get('gateway_busy') or d.get('active_agents') != 0:
        raise RuntimeError('Gateway is busy')
    ready=d.get('readiness',{})
    if ready.get('status') not in ('ready','ok'):
        raise RuntimeError('Gateway readiness unknown or degraded')
    queues=ready.get('checks',{}).get('background_queues',{})
    for k in ('active_api_runs','process_completions','active_delegations'):
        if queues.get(k) != 0:
            raise RuntimeError('Active or unknown queue: '+k)

def main():
    mode=sys.argv[1]
    d=get('/health/detailed')
    if mode=='idle': check_idle(d)
    elif mode=='health':
        if d.get('readiness',{}).get('status') not in ('ready','ok'):
            raise RuntimeError('Gateway readiness unknown or degraded')
    elif mode=='verify':
        import sqlite3,importlib.metadata
        assert sys.version_info[:2]==(3,13)
        assert sqlite3.sqlite_version_info >= (3,53,4)
        assert importlib.metadata.version('hermes-agent')=='0.21.4'
        assert pathlib.Path('/opt/hermes/.hermes_build_sha').read_text().strip()==sys.argv[2]
        from gateway.platforms.api_server import APIServerAdapter
        from tools import approval
        if os.environ.get('AGENT_NAME')=='moss':
            from agent.moss_memory_gate import policy,_key
            from plugins.memory.honcho.client import HonchoClientConfig
            assert policy() and len(_key())==32
            c=HonchoClientConfig.from_global_config()
            assert c.enabled and c.workspace_id=='moss-rodolfo' and c.peer_name=='Rodolfo' and c.ai_peer=='Moss'
        if os.environ.get('HERMES_WEBUI_PORT'):
            url='http://127.0.0.1:'+os.environ['HERMES_WEBUI_PORT']+'/health'
            with urllib.request.urlopen(url,timeout=10) as r: assert r.status==200
        assert d.get('readiness',{}).get('status') in ('ready','ok')
    else: raise ValueError(mode)
    print(json.dumps({'mode':mode,'result':'PASS','persona':os.environ.get('AGENT_NAME')}))
if __name__=='__main__': main()
