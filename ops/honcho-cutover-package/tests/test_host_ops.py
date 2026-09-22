import importlib.util
import json
import os
from pathlib import Path

import pytest

spec=importlib.util.spec_from_file_location('host_ops',Path(__file__).resolve().parents[1]/'host_ops.py')
assert spec is not None and spec.loader is not None
host=importlib.util.module_from_spec(spec)
spec.loader.exec_module(host)
pytestmark=pytest.mark.skipif(os.getuid()!=0,reason='Real ownership tests run as root in isolated candidate container')


@pytest.fixture
def filesystem(tmp_path,monkeypatch):
    home,stack,state=(tmp_path/x for x in ('home','stack','state'))
    for p in (home,stack,state): p.mkdir()
    pair=home/'profiles/moss/platforms/pairing/telegram-approved.json'
    pair.parent.mkdir(parents=True)
    pair.write_text(json.dumps({'12345':{'user_id':'12345'}}))
    monkeypatch.setattr(host,'HOME',home)
    monkeypatch.setattr(host,'STACK',stack)
    monkeypatch.setattr(host,'STATE',state)
    return home,stack,state


@pytest.mark.parametrize('fail_name',['moss-memory-gate.key','moss-memory-policy.json','honcho.json'])
@pytest.mark.parametrize('after',[False,True])
def test_staging_failure_recovers_all_owned_files(filesystem,monkeypatch,fail_name,after):
    home,_,_=filesystem
    original=host.atomic
    def injected(path,data,**kwargs):
        if path.name==fail_name and not after: raise OSError('injected failure')
        original(path,data,**kwargs)
        if path.name==fail_name and after: raise OSError('injected failure')
    monkeypatch.setattr(host,'atomic',injected)
    with pytest.raises(OSError): host.stage_config()
    host.unstage()
    for name in ('moss-memory-gate.key','moss-memory-policy.json','honcho.json'):
        assert not (home/name).exists()
    assert not list(home.glob('.*.new'))
    monkeypatch.setattr(host,'atomic',original)
    host.stage_config()
    host.unstage()


def test_toggle_and_cleanup(filesystem):
    home,_,_=filesystem
    host.stage_config()
    assert not json.loads((home/'honcho.json').read_text())['enabled']
    host.enabled(True)
    assert json.loads((home/'honcho.json').read_text())['enabled']
    host.enabled(False)
    host.unstage()
    assert not (home/'honcho.json').exists()


def test_config_update_crash_has_prior_custody(filesystem,monkeypatch):
    home,_,_=filesystem
    host.stage_config()
    original=host.atomic
    def injected(path,data,**kwargs):
        if path.name=='honcho.json': raise OSError('write failed after journal')
        original(path,data,**kwargs)
    monkeypatch.setattr(host,'atomic',injected)
    with pytest.raises(OSError): host.enabled(True)
    host.unstage()
    assert not (home/'honcho.json').exists()


def test_cleanup_refuses_drift_without_partial_removal(filesystem):
    home,_,_=filesystem
    host.stage_config()
    (home/'honcho.json').write_text('unowned content')
    with pytest.raises(ValueError,match='Configuration changed'): host.unstage()
    assert (home/'moss-memory-gate.key').exists()
    assert (home/'moss-memory-policy.json').exists()


def test_no_clobber(filesystem):
    home,_,_=filesystem
    (home/'honcho.json').write_text('existing')
    with pytest.raises(ValueError): host.stage_config()
    assert (home/'honcho.json').read_text()=='existing'
    assert not (home/'moss-memory-gate.key').exists()


def test_compose_rollback_and_drift(filesystem):
    _,stack,_=filesystem
    original=('services:\n  moss:\n    image: '+host.BASE+'\n').encode()
    (stack/'compose.yaml').write_bytes(original)
    host.compose_image('sha256:'+'a'*64)
    host.rollback_compose()
    assert (stack/'compose.yaml').read_bytes()==original
    host.rollback_compose()
    host.compose_image('sha256:'+'a'*64)
    (stack/'compose.yaml').write_text('someone else changed source')
    with pytest.raises(ValueError,match='source drift'): host.rollback_compose()


def test_policy_reads_require_root_regular_nonwritable_files(filesystem):
    from test_memory_gate import gate
    home,_,_=filesystem
    key=home/'key-test'
    key.write_bytes(b'z'*32)
    key.chmod(0o440)
    assert gate._root_read(key,0o027)==b'z'*32
    key.chmod(0o666)
    with pytest.raises(ValueError): gate._root_read(key,0o027)
    key.chmod(0o440)
    os.chown(key,99,100)
    with pytest.raises(ValueError): gate._root_read(key,0o027)
    link=home/'key-link'
    link.symlink_to(key)
    with pytest.raises(OSError): gate._root_read(link,0o027)
