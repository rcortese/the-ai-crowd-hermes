"""Reconstruct immutable build archives from official upstream plus private bundles.

Offline deployment does not call this script. Rebuilds need GitHub read access
and the six immutable derived-base images recorded in manifest.json.
"""
import hashlib,json,pathlib,subprocess,tempfile
root=pathlib.Path(__file__).resolve().parent
m=json.loads((root/'manifest.json').read_text())
expected=json.loads((root/'archive-sha256.json').read_text())
for kind,repo in [('agent','NousResearch/hermes-agent'),('webui','nesquena/hermes-webui')]:
 with tempfile.TemporaryDirectory(prefix='source-'+kind+'-') as td:
  def git(*args,**kw): return subprocess.run(['git','-C',td,*args],check=True,**kw)
  git('init','-q'); git('remote','add','origin','https://github.com/'+repo+'.git')
  git('fetch','--depth=1','origin',m['upstream_'+kind])
  git('bundle','verify',str(root/(kind+'-ports.bundle')))
  git('fetch',str(root/(kind+'-ports.bundle')),'refs/heads/*:refs/heads/*')
  commits={x[kind+'_commit'] for x in m['services'].values() if x[kind+'_commit']}
  for commit in commits:
   name=kind+'-'+commit+'.tar'; target=root/name
   if target.exists():
    if hashlib.sha256(target.read_bytes()).hexdigest()!=expected[name]: raise RuntimeError('Existing archive drift: '+name)
    continue
   temporary=target.with_suffix('.tar.new')
   with temporary.open('xb') as output: git('archive','--format=tar',commit,stdout=output)
   if hashlib.sha256(temporary.read_bytes()).hexdigest()!=expected[name]: raise RuntimeError('Archive mismatch: '+name)
   temporary.rename(target)
(root/'empty.tar').touch(exist_ok=True)
print('Immutable source archives verified; run build.py separately to rebuild candidates.')
