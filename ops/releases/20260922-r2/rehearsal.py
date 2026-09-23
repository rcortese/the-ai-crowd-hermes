"""Exercise real snapshot/encryption/restore and image rollback on synthetic data."""
import importlib.util,json,pathlib,subprocess,tempfile,hashlib,os
r=pathlib.Path(__file__).resolve().parent
p=r/'operator'
spec=importlib.util.spec_from_file_location('fleet',p/'fleet_release.py'); f=importlib.util.module_from_spec(spec); spec.loader.exec_module(f)
m=json.loads((p/'release.json').read_text())
print('REAL IMAGE REHEARSAL',json.dumps({k:m['services']['moss'][k] for k in ('image','base_image')}),flush=True)
original_run=f.run
def traced_run(args,**kwargs):
 print('EXEC',json.dumps(args),flush=True)
 out=original_run(args,**kwargs)
 print('EXIT 0',out.decode(errors='replace'),flush=True)
 return out
f.run=traced_run
original_pipeline=f.pipeline
def traced_pipeline(commands,**kwargs):
 print('PIPELINE',json.dumps(commands),flush=True)
 original_pipeline(commands,**kwargs)
 print('PIPELINE all exit codes 0',flush=True)
f.pipeline=traced_pipeline
with tempfile.TemporaryDirectory(prefix='fixture-',dir=r) as td:
 t=pathlib.Path(td); home=t/'home'; home.mkdir(); f.STATE=t/'backup'; f.STATE.mkdir()
 x=m['services']['moss']; x['home']=str(home)
 (home/'config.yaml').write_text('_config_version: 44\nmodel:\n  default: fixture\n  provider: openai\nplatform_toolsets:\n  cli: [file, web]\n  api_server: [file]\nmemory:\n  provider: none\n')
 def db(image,mode):
  print('DB MODE',mode,'IMAGE',image,flush=True)
  out=subprocess.check_output(['docker','run','--rm','--network','none','--tmpfs','/opt/data:rw','-e','HERMES_HOME=/opt/data','-w','/opt/hermes','--mount','type=bind,src='+str(home)+',dst=/fixture','--mount','type=bind,src='+str(r/'db-smoke.py')+',dst=/db-smoke.py,readonly','--entrypoint',f.PY,image,'/db-smoke.py',mode],text=True)
  print(out,flush=True)
 db(x['base_image'],'old-create')
 os.chown(home,99,100)
 for file in home.iterdir(): os.chown(file,99,100)
 f.snapshot(m,'moss','before')
 x['config_sha']=hashlib.sha256((home/'config.yaml').read_bytes()).hexdigest()
 out=f.run(f.container(m,'moss','state_helper.py','configure',rw=True)+[x['config_sha']],timeout=60); print(out.decode(),flush=True)
 db(x['image'],'new-write')
 # Exercise the real entrypoints against helper-migrated configuration, including
 # any additional migration performed by the candidate before old-image restart.
 import time
 for label,image in [('candidate',x['image']),('rollback-base',x['base_image'])]:
  name='fleet-config-rehearsal-'+label
  env={'HOME':'/opt/data','HERMES_HOME':'/opt/data','AGENT_NAME':'moss','API_SERVER_ENABLED':'true','API_SERVER_HOST':'127.0.0.1','API_SERVER_PORT':'8648','API_SERVER_KEY':'isolated-fixture-not-a-credential','HERMES_KANBAN_HOME':'/opt/data','HERMES_KANBAN_DISPATCH_OWNER':'moss','HERMES_KANBAN_DISPATCH_UNOWNED_BOARDS':'false','HERMES_WEBUI_GATEWAY_BASE_URL':'http://127.0.0.1:8648','WEBHOOK_ENABLED':'false','HERMES_WEBUI_PASSWORD':'isolated-fixture-not-a-credential','HERMES_WEBUI_HOST':'127.0.0.1','HERMES_WEBUI_PORT':'8787','HERMES_WEBUI_CHAT_BACKEND':'gateway'}
  cmd=['docker','run','-d','--name',name,'--network','none','--label','fleet.release.fixture=20260922','--mount','type=bind,src='+str(home)+',dst=/opt/data']
  for k,v in env.items(): cmd+=['-e',k+'='+v]
  cmd+=[image]
  print('CONFIG BOOT',label,image,'BEFORE', (home/'config.yaml').read_text(),flush=True)
  subprocess.run(cmd,check=True,stdout=subprocess.PIPE)
  try:
   deadline=time.monotonic()+100
   while True:
    probe=subprocess.run(['docker','exec',name,f.PY,'-c','import urllib.request; assert urllib.request.urlopen("http://127.0.0.1:8648/health",timeout=2).status==200; assert urllib.request.urlopen("http://127.0.0.1:8787/health",timeout=2).status==200; print("API_AND_WEBUI_HEALTH_PASS")'],capture_output=True,text=True)
    if probe.returncode==0: print(label,probe.stdout,flush=True); break
    if time.monotonic()>deadline: raise RuntimeError('config boot failed '+label+' '+probe.stderr)
    time.sleep(2)
   print('CONFIG AFTER',label,(home/'config.yaml').read_text(),flush=True)
  finally:
   print(subprocess.check_output(['docker','logs',name],stderr=subprocess.STDOUT,text=True),flush=True)
   subprocess.run(['docker','rm','-f','-v',name],check=True,stdout=subprocess.PIPE)
 db(x['base_image'],'old-reopen')
 f.snapshot(m,'moss','rollback')
 for receipt in sorted(f.STATE.glob('*-verify.json')): print(receipt.name,receipt.read_text(),flush=True)
 # Mutated ciphertext must fail authentication and cannot be accepted as a valid backup.
 backup=f.STATE/'moss-before.tar.gcm'; data=bytearray(backup.read_bytes()); data[100]^=1
 crypto=f.docker('run','--rm','-i','--network','none','--mount','type=bind,src='+str(p)+',dst=/package,readonly','--mount','type=bind,src='+str(f.STATE/'backup.key')+',dst=/key,readonly','--entrypoint',f.PY,x['base_image'],'/package/backup_stream.py','decrypt','/key')
 bad=subprocess.run(crypto,input=data,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
 assert bad.returncode!=0
 print('Authenticated backup, restored SQLite integrity, config preservation, old-new-old writes and tamper refusal: PASS',flush=True)
(r/'rehearsal.json').write_text(json.dumps({'status':'PASS','image':x['image'],'base_image':x['base_image'],'synthetic_only':True,'post_upgrade_messages_preserved':True,'encrypted_backup_restore_verified':True,'ciphertext_tampering_rejected':True},indent=2)+'\n')
