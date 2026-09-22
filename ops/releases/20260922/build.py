"""Candidate build only: no production lifecycle or configuration writes."""
import json, subprocess, pathlib, hashlib, sys
root=pathlib.Path(__file__).resolve().parent
m=json.loads((root/'manifest.json').read_text())
for service,x in m['services'].items():
    if len(sys.argv)>1 and service not in sys.argv[1:]: continue
    alias='the-ai-crowd/release-base:'+x['base_image'].split(':')[1][:16]
    subprocess.run(['docker','tag',x['base_image'],alias],check=True)
    assert subprocess.check_output(['docker','image','inspect','-f','{{.Id}}',alias],text=True).strip()==x['base_image']
    tag='the-ai-crowd/'+service+':candidate-20260922-'+x['agent_commit'][:12]
    command=['docker','build','--pull=false','-f',str(root/'Dockerfile'),'-t',tag,
             '--build-arg','BASE_IMAGE='+alias,
             '--build-arg','AGENT_COMMIT='+x['agent_commit'],
             '--build-arg','AGENT_TREE='+x['agent_tree'],
             '--build-arg','WEBUI_TREE='+x['webui_tree'],
             '--build-arg','DERIVED_BASE='+x['base_image'],
             '--build-arg','WEBUI_COMMIT='+(x['webui_commit'] or 'none'),
             '--build-arg','AGENT_ARCHIVE=agent-'+x['agent_commit']+'.tar',
             '--build-arg','WEBUI_ARCHIVE='+('webui-'+x['webui_commit']+'.tar' if x['webui_commit'] else 'empty.tar'),
             '--build-arg','RUNTIME_WORKDIR='+x['working_dir'],str(root)]
    print('BUILD',service,flush=True)
    subprocess.run(command,check=True)
    image=subprocess.check_output(['docker','image','inspect','-f','{{.Id}}',tag],text=True).strip()
    (root/f'image-{service}.json').write_text(json.dumps({'service':service,'image':image,'tag':tag,'base':x['base_image'],'agent':x['agent_commit'],'webui':x['webui_commit']},indent=2)+'\n')
    print('BUILT',service,image,flush=True)
