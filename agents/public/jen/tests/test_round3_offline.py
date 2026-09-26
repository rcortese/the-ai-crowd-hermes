#!/usr/bin/env python3
import copy, json, os, pathlib, shutil, subprocess, tempfile, unittest
ROOT = pathlib.Path(__file__).resolve().parents[1]
FAKE = '''#!/usr/bin/env python3
import json,os,pathlib,sys
a=sys.argv[1:]; root=pathlib.Path(os.environ['FIXTURE']); p=root/'calls.json'
calls=json.loads(p.read_text()) if p.exists() else []
method=a[a.index('-X')+1]; calls.append(method); p.write_text(json.dumps(calls))
config=json.loads((root/'fixture.json').read_text()); n=len(calls)
if config.get('network_at')==n: sys.exit(7)
if method=='POST':
 payload=json.loads(a[a.index('-d')+1]); assert payload=={'due_string':config['input']}
body=config['before'] if n==1 else config['after']
pathlib.Path(a[a.index('-o')+1]).write_text(json.dumps(body)); print(config.get('http',{}).get(str(n),'200'),end='')
'''
class Cases(unittest.TestCase):
 def setUp(self):
  self.t=tempfile.TemporaryDirectory(); self.d=pathlib.Path(self.t.name)
 def tearDown(self): self.t.cleanup()
 def adapter(self, *, after=None, before=None, date='2026-09-26', base=False, network_at=None, http=None):
  default={'id':'synthetic','due':{'date':'2026-09-25','string':'yesterday','is_recurring':False},'deadline':{'date':'2026-10-01'}}
  before=before or default
  if after is None:
   after=copy.deepcopy(default); after['due'].update(date=date,string='26 Sep')
  (self.d/'fixture.json').write_text(json.dumps(dict(before=before,after=after,input=date,network_at=network_at,http=http or {})))
  (self.d/'curl').write_text(FAKE); (self.d/'curl').chmod(0o755)
  (self.d/'calls.json').unlink(missing_ok=True)
  env={'PATH':str(self.d)+':/usr/local/bin:/usr/bin:/bin','TODOIST_API_TOKEN':'synthetic-offline','TODOIST_ENV_FILE':'/nonexistent','FIXTURE':str(self.d),'TMPDIR':str(self.d)}
  script=ROOT/'tools/todoist/todoist-api.sh'
  if base:
   old=subprocess.check_output(['git','-C',str(ROOT),'show','d19c4c26c36510a4f83fe6881401d403dc6e1609^:agents/public/jen/tools/todoist/todoist-api.sh'])
   script=self.d/'baseline-adapter.sh'; script.write_bytes(old)
  p=subprocess.run(['bash',str(script),'update-due','synthetic',date],env=env,capture_output=True,text=True)
  return p,json.loads((self.d/'calls.json').read_text())
 def test_iso_normalized_and_base_red(self):
  p,c=self.adapter(); self.assertEqual(p.returncode,0,p.stderr); self.assertEqual(c,['GET','POST','GET'])
  p,c=self.adapter(base=True); self.assertEqual(p.returncode,5); self.assertIn('verification_failed',p.stderr)
 def test_wrong_date(self):
  p,c=self.adapter(after={'due':{'date':'2026-09-27','is_recurring':False}}); self.assertEqual(p.returncode,5)
 def test_absent_due(self):
  p,c=self.adapter(after={'due':None}); self.assertEqual(p.returncode,5)
 def test_invalid_date_no_post(self):
  p,c=self.adapter(date='2026-02-30'); self.assertEqual(p.returncode,2); self.assertEqual(c,['GET'])
 def test_recurrence_guard(self):
  p,c=self.adapter(before={'due':{'is_recurring':True}}); self.assertEqual(p.returncode,6); self.assertEqual(c,['GET'])
 def test_recurrence_drift(self):
  p,c=self.adapter(after={'due':{'date':'2026-09-26','is_recurring':True},'deadline':{'date':'2026-10-01'}}); self.assertEqual(p.returncode,5)
 def test_deadline_drift(self):
  p,c=self.adapter(after={'due':{'date':'2026-09-26','is_recurring':False},'deadline':None}); self.assertEqual(p.returncode,5)
 def test_readback_unavailable(self):
  p,c=self.adapter(network_at=3); self.assertEqual(p.returncode,3); self.assertEqual(c,['GET','POST','GET'])
 def test_post_http_failure(self):
  p,c=self.adapter(http={'2':'500'}); self.assertEqual(p.returncode,4); self.assertEqual(c,['GET','POST'])
 def test_natural_text_not_date_equivalent(self):
  p,c=self.adapter(date='tomorrow'); self.assertEqual(p.returncode,5)
 def maintenance(self, fail=True, dry=False):
  (self.d/'bin').mkdir(); shutil.copytree(ROOT/'lib',self.d/'lib'); shutil.copy2(ROOT/'bin/jen-morning-due-adjust',self.d/'bin/maintenance')
  tasks=[{'id':str(i),'past_due_raw':True,'classification':{'category':'soft_surface'},'due':{'date':'2026-09-25','is_recurring':False},'deadline':None} for i in range(2)]
  sem=self.d/'sem'; sem.write_text('#!/usr/bin/env python3\nprint('+repr(json.dumps({'status':'ok','tasks':tasks}))+')\n'); sem.chmod(0o755)
  rt=self.d/'runtime'; rt.write_text('#!/usr/bin/env python3\nimport json,pathlib,sys\np=pathlib.Path('+repr(str(self.d/'count'))+')\nn=int(p.read_text())+1 if p.exists() else 1\np.write_text(str(n))\nfail='+repr(fail)+' and n==2\nprint(json.dumps({"status":"failed","partial":{"failure_class":"verification_failed"}} if fail else {"status":"ok"}))\nsys.exit(1 if fail else 0)\n'); rt.chmod(0o755)
  env=dict(os.environ,JEN_MORNING_DUE_ADJUST_SEMANTICS=str(sem),JEN_MORNING_DUE_ADJUST_TASK_RUNTIME=str(rt),JEN_MORNING_DUE_ADJUST_AUDIT_DIR=str(self.d/'audit'),JEN_MORNING_DUE_ADJUST_ENABLE_APPLY='1',TMPDIR=str(self.d))
  p=subprocess.run(['bash',str(self.d/'bin/maintenance'),'--dry-run' if dry else '--apply','--today','2026-09-26'],env=env,capture_output=True,text=True)
  return p,json.loads(p.stdout)
 def test_maintenance_partial_unknown(self):
  p,a=self.maintenance(); self.assertEqual(p.returncode,1,p.stderr); self.assertIsNone(a['summary']['write_count']); self.assertEqual(a['summary']['verified_write_count'],1); self.assertEqual(a['summary']['attempted_write_count'],2); self.assertEqual(a['effect_state'],'unknown'); self.assertEqual(a['runtime_failure_class'],'verification_failed'); self.assertEqual(a['downstream_reanchor']['status'],'blocked_by_upstream')
  audit=json.loads(pathlib.Path(a['audit_log_path']).read_text()); self.assertEqual([x['status'] for x in audit['writes']],['ok','failed'])
 def test_maintenance_success(self):
  p,a=self.maintenance(fail=False); self.assertEqual(p.returncode,0,p.stderr); self.assertEqual(a['summary']['write_count'],2)
 def test_maintenance_dry_run(self):
  p,a=self.maintenance(dry=True); self.assertEqual(p.returncode,0,p.stderr); self.assertFalse((self.d/'count').exists()); self.assertEqual(a['summary']['write_count'],0)
if __name__=='__main__': unittest.main(verbosity=2)
