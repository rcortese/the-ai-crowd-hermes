import pathlib,json,subprocess
r=pathlib.Path(__file__).resolve().parent
for service in ['moss','roy']:
 image=json.loads((r/f'image-{service}.json').read_text())['image']
 cmd=['docker','run','--rm','--mount','type=bind,src='+str(r/'testdeps')+',dst=/testdeps,readonly','-e','PYTHONPATH=/testdeps:/opt/hermes','--network','none','--user','99:100','--tmpfs','/opt/data:rw,uid=99,gid=100,mode=700','--tmpfs','/tmp:rw,mode=1777','-e','HERMES_HOME=/opt/data','-e','HOME=/opt/data','-e','HERMES_PROFILE=default','-w','/opt/hermes','--entrypoint','/opt/hermes/.venv/bin/python',image]
 tests=['tests/tools/test_web_tools_config.py','tests/tools/test_approval.py','tests/hermes_cli/test_auth_profile_fallback.py','tests/agent/test_memory_provider_init.py']
 if service=='moss': tests+=['tests/ai_crowd_honcho','tests/gateway/test_api_server_runs.py','tests/gateway/test_api_server_run_idempotency.py','tests/gateway/test_api_server_runs_extraction.py','tests/gateway/test_api_server_runs_import_isolation.py']
 p=subprocess.run(cmd+['-m','pytest','-q','-p','no:cacheprovider',*tests],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=240)
 (r/f'tests-{service}.log').write_text(p.stdout); print(service,p.returncode,p.stdout[-4500:],flush=True)
 p.check_returncode()
 cmd[cmd.index('-w')+1]='/opt/hermes-webui'
 tests=['tests/test_gateway_approval_runs_api.py','tests/test_ai_crowd_request_id_contract.py','tests/test_ai_crowd_v05276_port.py','tests/test_ai_crowd_v05276_followup.py','tests/test_ai_crowd_title_topic_priority.py']
 p=subprocess.run(cmd+['-m','pytest','-q','-p','no:cacheprovider',*tests],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=240)
 (r/f'tests-webui-{service}.log').write_text(p.stdout); print('webui',service,p.returncode,p.stdout[-4500:],flush=True)
 p.check_returncode()
