#!/usr/bin/env python3
"""Observation-only UX around the sealed release executor; no gate bypass."""
import fcntl
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent
STATE = Path('/mnt/user/appdata/the-ai-crowd/state/private/backups/fleet-release-20260922/transaction.json')
RUNS = ROOT / 'visual-runs'

def save(path, data):
    tmp = path.with_suffix('.tmp')
    tmp.write_text(json.dumps(data) + '\n')
    tmp.replace(path)

def identity(pid):
    try:
        text = Path('/proc/%s/stat' % pid).read_text().rsplit(')', 1)[1].split()
        return None if text[0] == 'Z' else text[19]
    except (FileNotFoundError, ProcessLookupError):
        return None

def phase():
    try:
        d = json.loads(STATE.read_text())
        return d['phase'] + ' | serviços iniciados: ' + ', '.join(d.get('attempted', []))
    except FileNotFoundError:
        return 'PRÉ-CHECAGEM | transação ainda não criada'

def worker(directory, lockfd):
    directory = Path(directory)
    # Keep the launch lock for the entire execution, independently of SSH.
    os.fstat(lockfd)
    rc = 1
    try:
        mode = json.loads((directory / 'start.json').read_text())['mode']
        print('Executor iniciado. Validando pacote, baseline e ociosidade...', flush=True)
        rc = subprocess.call([sys.executable, '-u', str(ROOT / 'fleet_release.py'), mode])
        print('Executor terminou com código %s.' % rc, flush=True)
    finally:
        save(directory / 'result.json', {'exit_code': rc, 'finished': time.time()})
    return rc

def watch(directory):
    directory = Path(directory)
    meta = json.loads((directory / 'start.json').read_text())
    print('Acompanhando: ' + str(directory), flush=True)
    print('Ctrl+C apenas fecha a visualização; a atualização continua no host.', flush=True)
    offset = 0
    previous = None
    last = 0
    try:
        while True:
            with (directory / 'output.log').open() as log:
                log.seek(offset)
                text = log.read()
                offset = log.tell()
            if text:
                print(text, end='', flush=True)
            current = phase()
            if current != previous or time.monotonic() - last >= 10:
                print('[%s] %s' % (time.strftime('%H:%M:%S'), current), flush=True)
                previous, last = current, time.monotonic()
            result = directory / 'result.json'
            if result.exists():
                # Read trailing output after the terminal receipt becomes visible.
                with (directory / 'output.log').open() as log:
                    log.seek(offset)
                    print(log.read(), end='', flush=True)
                rc = json.loads(result.read_text())['exit_code']
                print('\n' + ('CONCLUÍDO SEM ERRO' if rc == 0 else 'FALHOU — não repita apply sem verificar a causa.'))
                print('Log completo: ' + str(directory / 'output.log'))
                return rc
            if identity(meta['pid']) != meta['identity']:
                print('INTERROMPIDO SEM RESULTADO FINAL. Verifique estado/log antes de recuperar.')
                return 1
            time.sleep(1)
    except KeyboardInterrupt:
        print('\nVisualização fechada. Retome com: bash %s watch' % (ROOT / 'run-visual.sh'))
        return 130

def main():
    if len(sys.argv) == 4 and sys.argv[1] == '_worker':
        return worker(sys.argv[2], int(sys.argv[3]))
    if os.geteuid() != 0 or socket.gethostname() != 'MEDIA':
        raise RuntimeError('Execute como root@media.lan')
    mode = sys.argv[1] if len(sys.argv) == 2 else 'watch' if len(sys.argv) == 1 else ''
    if mode not in ('apply', 'recover', 'check', 'watch', 'status'):
        raise RuntimeError('Uso: bash run-visual.sh [apply|recover|check|watch|status]')
    if mode == 'check':
        return subprocess.call([sys.executable, '-u', str(ROOT / 'fleet_release.py'), 'check'])
    if mode in ('watch', 'status'):
        latest = RUNS / 'latest.json'
        if not latest.exists():
            print('Nenhuma execução pelo visualizador. Estado da transação: ' + phase())
            return 0
        return watch(json.loads(latest.read_text())['directory'])
    os.umask(0o077)
    RUNS.mkdir(exist_ok=True)
    lock = os.open(str(RUNS / 'launch.lock'), os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(lock)
        print('Já existe execução visual ativa; conectando sem iniciar outra.')
        return watch(json.loads((RUNS / 'latest.json').read_text())['directory'])
    print('Esta operação pode recriar os seis agentes, incluindo Moss/WebUI.')
    print('Feche tarefas ativas e não envie mensagens até a conclusão.')
    if input('Digite APLICAR para continuar: ') != 'APLICAR':
        os.close(lock)
        print('Cancelado; nenhuma execução iniciada.')
        return 1
    directory = RUNS / ('run-' + str(time.time_ns()))
    directory.mkdir()
    save(directory / 'start.json', {'mode': mode})
    with (directory / 'output.log').open('w') as log:
        child = subprocess.Popen([sys.executable, '-u', str(Path(__file__).resolve()), '_worker', str(directory), str(lock)], stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, start_new_session=True, pass_fds=(lock,))
    save(directory / 'start.json', {'mode': mode, 'pid': child.pid, 'identity': identity(child.pid)})
    save(RUNS / 'latest.json', {'directory': str(directory)})
    os.close(lock)
    return watch(directory)

if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as exc:
        print('ERRO: ' + str(exc), file=sys.stderr)
        sys.exit(1)
