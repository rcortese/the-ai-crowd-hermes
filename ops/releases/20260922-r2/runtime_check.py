"""Credential-safe in-container gates. No model calls or external writes."""
import json, os, sys, pathlib, urllib.request, urllib.error

class GateError(RuntimeError):
    def __init__(self, code):
        self.code=code
        super().__init__(code)

def require(condition,code):
    if not condition: raise GateError(code)

def api_settings():
    from dotenv import dotenv_values
    home=pathlib.Path(os.environ.get('HERMES_HOME','/opt/data'))
    values=dotenv_values(home/'.env') if (home/'.env').exists() else {}
    def setting(name):
        value=values[name] if name in values else os.environ.get(name)
        if not value: raise GateError('SETTINGS')
        return value
    return setting('API_SERVER_PORT'),setting('API_SERVER_KEY')

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self,*args,**kwargs): raise GateError('REDIRECT')

def get(path):
    port,key=api_settings()
    require(port.isdecimal() and 1 <= int(port) <= 65535,'SETTINGS')
    req=urllib.request.Request('http://127.0.0.1:'+port+path,headers={'Authorization':'Bearer '+key})
    with urllib.request.build_opener(urllib.request.ProxyHandler({}),NoRedirect()).open(req,timeout=10) as r:
        return json.load(r)

def check_ready(d):
    require(d.get('readiness',{}).get('status') in ('ready','ok'),'READINESS')

def check_idle(d):
    require(not d.get('gateway_busy') and d.get('active_agents')==0,'BUSY')
    check_ready(d)
    queues=d.get('readiness',{}).get('checks',{}).get('background_queues',{})
    for k in ('active_api_runs','process_completions','active_delegations'):
        require(queues.get(k)==0,'BUSY')

def main():
    mode=sys.argv[1]
    d=get('/health/detailed')
    if mode=='idle': check_idle(d)
    elif mode=='health': check_ready(d)
    elif mode=='verify':
        import sqlite3,importlib.metadata
        require(sys.version_info[:2]==(3,13),'PYTHON_VERSION')
        require(sqlite3.sqlite_version_info >= (3,53,4),'SQLITE_VERSION')
        require(importlib.metadata.version('hermes-agent')=='0.21.4','AGENT_VERSION')
        require(pathlib.Path('/opt/hermes/.hermes_build_sha').read_text().strip()==sys.argv[2],'AGENT_COMMIT')
        from gateway.platforms.api_server import APIServerAdapter
        from tools import approval
        if os.environ.get('AGENT_NAME')=='moss':
            from agent.moss_memory_gate import policy,_key
            from plugins.memory.honcho.client import HonchoClientConfig
            require(bool(policy()) and len(_key())==32,'HONCHO_POLICY')
            c=HonchoClientConfig.from_global_config()
            require(c.enabled and c.workspace_id=='moss-rodolfo' and c.peer_name=='Rodolfo' and c.ai_peer=='Moss','HONCHO_CONFIG')
        if os.environ.get('HERMES_WEBUI_PORT'):
            port=os.environ['HERMES_WEBUI_PORT']
            require(port.isdecimal() and 1 <= int(port) <= 65535,'SETTINGS')
            url='http://127.0.0.1:'+port+'/health'
            with urllib.request.build_opener(urllib.request.ProxyHandler({}),NoRedirect()).open(url,timeout=10) as r:
                require(r.status==200,'WEBUI_HEALTH')
        check_ready(d)
    else: raise GateError('MODE')
    print(json.dumps({'result':'PASS'}))

def entrypoint():
    try: main()
    except Exception as exc:
        # Never print exception messages, URLs, response bodies, or import logs.
        code='INTERNAL'
        if isinstance(exc,GateError): code=exc.code
        elif isinstance(exc,urllib.error.HTTPError): code='HTTP_'+str(exc.code) if 100 <= exc.code <= 599 else 'INTERNAL'
        elif isinstance(exc,(urllib.error.URLError,TimeoutError,ConnectionError)): code='CONNECT'
        elif isinstance(exc,ImportError): code='IMPORT'
        print(json.dumps({'result':'FAIL','code':code}))
        return 1
    return 0
if __name__=='__main__': sys.exit(entrypoint())
