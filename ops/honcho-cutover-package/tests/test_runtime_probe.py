import sys
from types import SimpleNamespace
import pytest
from test_runs_memory_integration import module, ROOT


@pytest.mark.parametrize('enabled,capable,base,passes', [
    (True,True,'http://moss:8648',True),
    (False,True,'http://moss:8648',False),
    (True,False,'http://moss:8648',False),
    (True,True,'http://other:8648',False),
])
def test_runs_preflight(monkeypatch, enabled, capable, base, passes):
    probe = module('candidate_runtime_probe', ROOT/'runtime_probe.py')
    monkeypatch.setattr('hermes_cli.config.load_config',lambda:{})
    monkeypatch.setitem(sys.modules,'api.gateway_chat',SimpleNamespace(
        _gateway_use_runs_api_enabled=lambda cfg:enabled,
        _gateway_base_url=lambda cfg:base, _gateway_api_key=lambda:'fixture'))
    monkeypatch.setitem(sys.modules,'api.config',SimpleNamespace(
        gateway_supports_approval=lambda url,key:capable))
    if passes:
        probe.webui_runs()
    else:
        with pytest.raises(ValueError): probe.webui_runs()
