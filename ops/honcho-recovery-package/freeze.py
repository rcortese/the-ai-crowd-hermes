"""Freeze source hashes and an integration-only diff from the observed runtime.
Run only before review; never refresh a reviewed package silently on the host.
"""
import difflib
import hashlib
from pathlib import Path

ROOT=Path(__file__).resolve().parent
PAIRS={
    'overlay/plugins/memory/honcho/cli.py':'/opt/hermes/plugins/memory/honcho/cli.py',
    'overlay/agent/agent_init.py':'/opt/hermes/agent/agent_init.py',
    'overlay/plugins/memory/honcho/__init__.py':'/opt/hermes/plugins/memory/honcho/__init__.py',
    'overlay/plugins/memory/honcho/client.py':'/opt/hermes/plugins/memory/honcho/client.py',
    'overlay/gateway/platforms/api_server.py':'/opt/hermes/gateway/platforms/api_server.py',
    'overlay/gateway/platforms/api_server_runs.py':'/opt/hermes/gateway/platforms/api_server_runs.py',
    'webui/api/routes.py':'/opt/hermes-webui/api/routes.py',
    'webui/api/gateway_chat.py':'/opt/hermes-webui/api/gateway_chat.py',
}

if __name__=='__main__':
    baseline=[]
    diffs=[]
    for relative,live in PAIRS.items():
        a=Path(live).read_bytes()
        b=(ROOT/relative).read_bytes()
        baseline.append(hashlib.sha256(a).hexdigest()+'  '+live+'\n')
        diffs.extend(difflib.unified_diff(a.decode().splitlines(True),b.decode().splitlines(True),
                                        fromfile=live,tofile=relative))
    (ROOT/'BASELINE.sha256').write_text(''.join(baseline))
    installed=[]
    for prefix,destination in [('overlay','/opt/hermes'),('webui','/opt/hermes-webui')]:
        for p in sorted((ROOT/prefix).rglob('*.py')):
            if '__pycache__' not in p.parts:
                installed.append(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+destination+'/'+p.relative_to(ROOT/prefix).as_posix()+'\n')
    (ROOT/'INSTALLED.sha256').write_text(''.join(installed))
    (ROOT/'INTEGRATION.diff').write_text(''.join(diffs))
    hashes=[]
    for p in sorted(ROOT.rglob('*')):
        relative=p.relative_to(ROOT)
        if any(x in {'.git','__pycache__','.pytest_cache','reports'} for x in relative.parts): continue
        if p.name=='SHA256SUMS' or not p.is_file(): continue
        if p.is_symlink(): raise ValueError('Symlink in package')
        hashes.append(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+relative.as_posix()+'\n')
    (ROOT/'SHA256SUMS').write_text(''.join(hashes))
    print('frozen_files',len(hashes),'baseline_files',len(baseline))
