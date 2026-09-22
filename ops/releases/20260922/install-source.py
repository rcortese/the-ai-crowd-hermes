"""Install only immutable Git archives into the image, preserving image-owned deps."""
import json, os, shutil, sys, tarfile
from pathlib import Path
agent_sha, webui_sha = sys.argv[1:]
root=Path('/opt/hermes')
# Keep intentionally retired plugin families retired for each persona.
pruned=[p for p in ('platforms/google_chat','platforms/irc','platforms/line','platforms/simplex','platforms/teams','google_meet','spotify','teams_pipeline','observability/langfuse','memory/byterover','memory/hindsight','memory/holographic','memory/mem0','memory/openviking','memory/retaindb','memory/supermemory','image_gen/xai','image_gen/openai-codex','video_gen/fal','video_gen/xai') if not (root/'plugins'/p).exists()]
# Delete old versioned files absent in the new source, not venv/node_modules/browser caches.
with tarfile.open('/tmp/agent.tar') as archive:
    new=set(archive.getnames())
    old=json.loads(Path('/tmp/old-agent-files.json').read_text())
    for name in old:
        p=root/name
        if name not in new and (p.is_file() or p.is_symlink()): p.unlink()
    archive.extractall(root,filter='data')
for name in pruned:
    p=root/'plugins'/name
    if p.exists(): shutil.rmtree(p)
(root/'.hermes_build_sha').write_text(agent_sha+'\n')
(root/'.install_method').write_text('docker\n')
p=Path('/etc/hermes/image-provenance.json')
p.write_text(json.dumps({'schema':1,'deployment_kind':'image','manager':'docker','image':'the-ai-crowd/hermes-agent','version':'0.21.4','revision':agent_sha})+'\n')
# The s6 initializer already execs /opt/hermes/docker/stage2-hook.sh.
if webui_sha != 'none':
    w=Path('/opt/hermes-webui')
    if w.exists(): shutil.rmtree(w)
    with tarfile.open('/tmp/webui.tar') as archive: archive.extractall(w,filter='data')
    (w/'api/_version.py').write_text("__version__ = 'v0.52.113-ai-crowd-"+webui_sha[:12]+"'\n")
print('immutable_source_installed',agent_sha,webui_sha)
