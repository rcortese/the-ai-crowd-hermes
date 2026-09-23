"""Isolated image checks. Never mounts production data or joins its networks."""
import json,pathlib,subprocess
root=pathlib.Path(__file__).resolve().parent
m=json.loads((root/'manifest.json').read_text())
probe='''import sys,sqlite3,json,pathlib,importlib.metadata,subprocess
assert sys.version_info[:2]==(3,13)
assert sqlite3.sqlite_version_info >= (3,53,4)
assert importlib.metadata.version('hermes-agent')=='0.21.4'
from hermes_state import SessionDB
from hermes_cli import auth,plugins
from gateway.platforms.api_server import APIServerAdapter
from tools import approval,web_tools
p=pathlib.Path('/opt/data/state.db'); db=SessionDB(db_path=p); db.create_session('isolated-smoke',source='cli'); db.append_message('isolated-smoke','user','isolated orchid'); assert db.search_messages('orchid'); db.close()
assert subprocess.check_output(['node','--version'],text=True).strip().startswith('v26.')
print(json.dumps({'python':sys.version.split()[0],'sqlite':sqlite3.sqlite_version,'agent':importlib.metadata.version('hermes-agent'),'imports_and_session_db':'PASS'}))'''
for s,x in m['services'].items():
 receipt=json.loads((root/f'image-{s}.json').read_text()); image=receipt['image']
 d=json.loads(subprocess.check_output(['docker','image','inspect',image]))[0]
 assert d['Config']['Labels']['the-ai-crowd.agent-source-commit']==x['agent_commit']
 assert d['Config']['Labels']['the-ai-crowd.agent-source-tree']==x['agent_tree']
 cmd=['docker','run','--rm','--network','none','--user','99:100','--tmpfs','/opt/data:rw,uid=99,gid=100,mode=700','--tmpfs','/tmp:rw,mode=1777','-e','HERMES_HOME=/opt/data','-e','HOME=/opt/data','-e','HERMES_PROFILE=default','-w','/opt/hermes','--entrypoint','/opt/hermes/.venv/bin/python',image]
 p=subprocess.run(cmd+['-c',probe],capture_output=True,text=True,timeout=120)
 print(s,p.stdout,p.stderr,flush=True); p.check_returncode()
 (root/f'smoke-{s}.json').write_text(json.dumps({'service':s,'image':image,'result':'PASS','probe':json.loads(p.stdout.strip().splitlines()[-1])},indent=2)+'\n')
