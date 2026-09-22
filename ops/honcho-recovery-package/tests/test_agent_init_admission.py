"""Exercise the real initialization entry before any model/network setup."""
import inspect
import sys
from types import SimpleNamespace

import pytest
from test_memory_gate import gate, isolated
from test_runs_memory_integration import module, ROOT


@pytest.mark.parametrize('admitted,explicit,safe,session,key,expected', [
    (True, False, False, 's1', 'webui:s1', False),
    (False, False, False, 's1', 'webui:s1', True),
    (True, True, False, 's1', 'webui:s1', True),
    (True, False, True, 's1', 'webui:s1', True),
    (True, False, False, 's2', 'webui:s2', True),
    (True, False, False, 'rotated', 'webui:s1', False),
])
def test_actual_init_admission(monkeypatch, admitted, explicit, safe, session, key, expected):
    monkeypatch.setitem(sys.modules, 'agent.moss_memory_gate', gate)
    init = module('candidate_agent_init', ROOT/'overlay/agent/agent_init.py')
    for name in ('HERMES_SAFE_MODE','HERMES_IGNORE_RULES','HERMES_IGNORE_USER_CONFIG'):
        monkeypatch.delenv(name, raising=False)
    if safe:
        monkeypatch.setenv('HERMES_SAFE_MODE','true')
    if admitted:
        gate.api_admission.set({'principal':'Rodolfo','session_id':'s1','profile':'default'})
    class StopBeforeModel(Exception):
        pass
    observed = []
    def stop(*args):
        # Real init_agent has made its memory decision and propagated identity;
        # stop before routing/client/tool initialization can have side effects.
        frame = inspect.currentframe()
        assert frame is not None and frame.f_back is not None
        observed.append(frame.f_back.f_locals['skip_memory'])
        raise StopBeforeModel
    monkeypatch.setattr(init, '_resolve_api_mode', stop)
    monkeypatch.setattr(init, '_install_safe_stdio', lambda: None)
    with pytest.raises(StopBeforeModel):
        init.init_agent(SimpleNamespace(), platform='api_server', session_id=session,
                        gateway_session_key=key, skip_memory=explicit)
    assert observed == [expected]
