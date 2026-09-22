import copy,importlib.util,json,pathlib,sqlite3,tempfile,unittest
from unittest.mock import patch,Mock
ROOT=pathlib.Path(__file__).parent

def load(name):
 s=importlib.util.spec_from_file_location(name,ROOT/(name+'.py')); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); return m
f=load('fleet_release'); h=load('state_helper'); r=load('runtime_check')

class Contracts(unittest.TestCase):
 def test_image_only_topology(self):
  a={'services':{s:{'image':'old','environment':{'K':'v'},'volumes':['a:b']} for s in f.ORDER}}
  b=copy.deepcopy(a)
  for s in f.ORDER: b['services'][s]['image']='new'
  f.verify_topology(a,b)
  b['services']['moss']['volumes']=['wrong:b']
  with self.assertRaises(RuntimeError): f.verify_topology(a,b)
 def test_unknown_service_rejected(self):
  with self.assertRaises(RuntimeError): f.verify_topology({'services':{}},{'services':{}})
 def test_config_only_known_metadata(self):
  raw=b'_config_version: 32\nmodel: private-model\nplatform_toolsets:\n  cli: [file, web]\n  telegram: [connections, file]\n'
  out=h.config_bytes(raw); c=h.yaml.safe_load(out)
  self.assertEqual(c['_config_version'],32)
  self.assertEqual(c['platform_toolsets']['cli'],['file','web'])
  self.assertEqual(c['known_builtin_toolsets'],{'cli':['connections']})
  self.assertEqual(h.config_bytes(out),out)
 def test_config_invalid(self):
  for raw in (b'[]',b'known_builtin_toolsets: []',b'platform_toolsets: {cli: bad}'):
   with self.assertRaises(ValueError): h.config_bytes(raw)
 def test_idle_fail_closed(self):
  d={'active_agents':0,'readiness':{'status':'ready','checks':{'background_queues':dict(active_api_runs=0,process_completions=0,active_delegations=0)}}}
  r.check_idle(d)
  for key in ('active_api_runs','process_completions','active_delegations'):
   changed=copy.deepcopy(d); changed['readiness']['checks']['background_queues'].pop(key)
   with self.assertRaises(RuntimeError): r.check_idle(changed)
  with self.assertRaises(RuntimeError): r.check_idle({})
 def test_atomic_write(self):
  with tempfile.TemporaryDirectory() as td:
   p=pathlib.Path(td)/'receipt'; f.atomic(p,b'old'); f.atomic(p,b'new'); self.assertEqual(p.read_bytes(),b'new'); self.assertFalse(p.with_name('receipt.new').exists())
 def test_atomic_refuses_existing_temp(self):
  with tempfile.TemporaryDirectory() as td:
   p=pathlib.Path(td)/'receipt'; p.with_name('receipt.new').write_bytes(b'other')
   with self.assertRaises(FileExistsError): f.atomic(p,b'new')
 def test_config_cas(self):
  with tempfile.TemporaryDirectory() as td,patch.object(h,'ROOT',pathlib.Path(td)):
   p=pathlib.Path(td)/'config.yaml'; p.write_text('platform_toolsets: {cli: [file]}\n')
   with self.assertRaises(ValueError): h.configure('wrong')
   self.assertEqual(p.read_text(),'platform_toolsets: {cli: [file]}\n')
 def test_review_blocks_before_state_and_lifecycle(self):
  with tempfile.TemporaryDirectory() as td:
   root=pathlib.Path(td); (root/'review.json').write_text('{"verdict":"BLOCKED"}')
   with patch.object(f,'ROOT',root),patch.object(f,'STATE',root/'state'),patch.object(f,'check'),patch.object(f,'run') as run:
    with self.assertRaises(RuntimeError): f.apply({})
    run.assert_not_called(); self.assertFalse((root/'state').exists())
 def test_preflight_failure_no_rollback(self):
  with patch.object(f,'check',side_effect=RuntimeError('drift')),patch.object(f,'rollback') as rb:
   with self.assertRaises(RuntimeError): f.apply({})
   rb.assert_not_called()
 def test_rollback_order_and_no_database_restore(self):
  state={'attempted':['jen','moss']}; m={'services':{s:{'base_image':'old','image':'new'} for s in state['attempted']}}
  with patch.object(f,'current_image',return_value='new'),patch.object(f,'persist'),patch.object(f,'restore_compose'),patch.object(f,'snapshot') as snap,patch.object(f,'run') as run,patch.object(f,'healthy') as health:
   f.rollback(m,state)
   self.assertEqual([x.args[1] for x in snap.call_args_list],['moss','jen'])
   self.assertEqual(state['phase'],'ROLLED_BACK')
   self.assertEqual([x.args for x in health.call_args_list],[('moss','old'),('jen','old')])
   self.assertTrue(all('up' in x.args[0] for x in run.call_args_list))
 def test_rollback_external_compose_drift(self):
  with tempfile.TemporaryDirectory() as td:
   root=pathlib.Path(td); (root/'compose').write_bytes(b'external'); (root/'compose.before.yaml').write_bytes(b'old')
   with patch.object(f,'STATE',root),patch.object(f,'COMPOSE',root/'compose'):
    with self.assertRaises(RuntimeError): f.restore_compose({'files':{'compose.candidate.yaml':'wrong'}},{})
    self.assertEqual((root/'compose').read_bytes(),b'external')
 def test_rollback_refuses_third_image_before_source_change(self):
  m={'services':{'moss':{'base_image':'old','image':'new'}}}
  with patch.object(f,'persist'),patch.object(f,'current_image',return_value='other'),patch.object(f,'restore_compose') as restore:
   with self.assertRaises(RuntimeError): f.rollback(m,{'attempted':['moss']})
   restore.assert_not_called()
 def exercise_apply(self,fail=False):
  from contextlib import ExitStack
  with tempfile.TemporaryDirectory() as td,ExitStack() as es:
   root=pathlib.Path(td); compose=root/'compose.yaml'; compose.write_bytes(b'old')
   (root/'compose.candidate.yaml').write_bytes(b'new'); (root/'release.json').write_bytes(b'{}')
   (root/'review.json').write_text(json.dumps({'verdict':'APPROVED WITHOUT CHANGES','manifest_sha':f.sha(b'{}')}))
   for name,value in [('ROOT',root),('COMPOSE',compose),('STATE',root/'state'),('ORDER',['moss'])]: es.enter_context(patch.object(f,name,value))
   es.enter_context(patch.object(f,'install_source'))
   es.enter_context(patch.object(f,'check')); es.enter_context(patch.object(f,'snapshot')); es.enter_context(patch.object(f,'probe'))
   es.enter_context(patch.object(f,'container',return_value=['configure']))
   es.enter_context(patch.object(f,'current_image',return_value='new'))
   run=es.enter_context(patch.object(f,'run',return_value=b'{"config_sha":"changed"}'))
   health=es.enter_context(patch.object(f,'healthy',side_effect=[RuntimeError('not healthy'),None] if fail else None))
   m={'services':{'moss':{'config_sha':'oldhash','image':'new','base_image':'old','agent_commit':'commit'}},'files':{'compose.candidate.yaml':f.sha(b'new')}}
   if fail:
    with self.assertRaises(RuntimeError): f.apply(m)
   else: f.apply(m)
   state=json.loads((root/'state/transaction.json').read_text())
   self.assertEqual(state['phase'],'ROLLED_BACK' if fail else 'SUCCEEDED')
   self.assertEqual(compose.read_bytes(),b'old' if fail else b'new')
   self.assertEqual(state['attempted'],['moss'])
 def test_apply_success_receipt(self): self.exercise_apply()
 def test_apply_health_failure_rolls_back(self): self.exercise_apply(fail=True)
 def test_package_tamper_and_traversal(self):
  with tempfile.TemporaryDirectory() as td,patch.object(f,'ROOT',pathlib.Path(td)):
   p=pathlib.Path(td)/'code'; p.write_bytes(b'code'); m={'files':{'code':f.sha(b'code')}}
   f.verify_package(m); p.write_bytes(b'changed')
   with self.assertRaises(RuntimeError): f.verify_package(m)
   with self.assertRaises(RuntimeError): f.verify_package({'files':{'../escape':'hash'}})
 def test_versioned_source_import(self):
  with tempfile.TemporaryDirectory() as td:
   base=pathlib.Path(td); source=base/'source'; source.mkdir(); stack=base/'stack'; (stack/'ops/releases').mkdir(parents=True)
   for name,data in [('release.json',b'{}'),('review.json',b'{}'),('code.py',b'pass\n')]: (source/name).write_bytes(data)
   with patch.object(f,'ROOT',source),patch.object(f,'STACK',stack):
    m={'files':{'code.py':f.sha(b'pass\n')}}; f.install_source(m)
    self.assertEqual((stack/'ops/releases/20260922/code.py').read_bytes(),b'pass\n')
    with self.assertRaises(RuntimeError): f.install_source(m)
 def test_snapshot_selection_excludes_workspace(self):
  with tempfile.TemporaryDirectory() as td,patch.object(h,'ROOT',pathlib.Path(td)):
   root=pathlib.Path(td); (root/'workspace').mkdir(); (root/'workspace/config.yaml').write_text('secret')
   (root/'config.yaml').write_text('{}'); sqlite3.connect(root/'state.db').close()
   self.assertEqual({p.name for p in h.selected()},{'config.yaml','state.db'})
if __name__=='__main__': unittest.main()
