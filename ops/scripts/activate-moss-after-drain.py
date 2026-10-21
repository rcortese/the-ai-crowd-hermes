#!/usr/bin/env python3
"""One bounded host handoff; not a scheduler or recurring worker.

Observe the current WebUI's activity until its turn drains, then invoke the
reviewed host activation. Exit without mutation if observation is inconclusive,
the container changes, or activity has not drained within ten minutes.
"""
import json
from pathlib import Path
import subprocess
import time


def main():
    name = 'the-ai-crowd-moss-1'
    original = subprocess.check_output(['docker', 'inspect', name, '--format', '{{.Id}}'], text=True).strip()
    health_script = ('import json,urllib.request; '
                     'print(json.dumps(json.load(urllib.request.urlopen("http://127.0.0.1:8787/health",timeout=5))))')
    deadline = time.monotonic() + 600
    print('waiting-for-current-webui-turn-to-drain', flush=True)
    while time.monotonic() < deadline:
        current = subprocess.check_output(['docker', 'inspect', name, '--format', '{{.Id}}'], text=True).strip()
        if current != original:
            raise SystemExit('container changed concurrently; no mutation')
        health = json.loads(subprocess.check_output([
            'docker', 'exec', '--user', '99:100', original,
            '/opt/hermes/.venv/bin/python', '-c', health_script,
        ], text=True, timeout=15))
        if health.get('status') != 'ok' or not all(k in health for k in ('active_runs', 'active_streams')):
            raise SystemExit('activity observation inconclusive; no mutation')
        if health['active_runs'] == 0 and health['active_streams'] == 0:
            print('webui-drained-invoking-reviewed-activation', flush=True)
            subprocess.run(['python3', str(Path(__file__).with_name('apply-paperclip-external-origin.py')),
                            '--component', 'moss'], check=True)
            print('moss-activation-returned-see-receipt-functional-acceptance-still-required', flush=True)
            return
        time.sleep(3)
    raise SystemExit('activity did not drain within ten minutes; no mutation')


if __name__ == '__main__':
    main()
