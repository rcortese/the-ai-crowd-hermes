"""Real candidate Runs lifecycle, with model/network work replaced by explicit unit doubles."""
import asyncio
import contextlib
import importlib.util
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest
from test_memory_gate import gate, isolated  # fixture and shared candidate module

ROOT=Path(__file__).resolve().parents[1]


def module(name,path):
    spec=importlib.util.spec_from_file_location(name,path)
    assert spec is not None and spec.loader is not None
    mod=importlib.util.module_from_spec(spec)
    sys.modules[name]=mod
    spec.loader.exec_module(mod)
    return mod


@pytest.mark.parametrize('authorized',[True,False])
def test_runs_create_and_executor_preserve_server_admission(monkeypatch,authorized):
    monkeypatch.setitem(sys.modules,'agent.moss_memory_gate',gate)
    runs=module('candidate_runs',ROOT/'overlay/gateway/platforms/api_server_runs.py')
    provider_module=module('candidate_honcho_provider',ROOT/'overlay/plugins/memory/honcho/__init__.py')
    from plugins.memory.honcho.client import HonchoClientConfig
    cfg=HonchoClientConfig(enabled=True,base_url='http://honcho-api:8000',workspace_id='moss-rodolfo',
                           peer_name='Rodolfo',ai_peer='Moss',session_strategy='per-session')
    monkeypatch.setattr(HonchoClientConfig,'from_global_config',classmethod(lambda cls:cfg))
    monkeypatch.setattr(provider_module.HonchoMemoryProvider,'_start_session_init_background',lambda *a,**k:None)
    import tools.approval
    monkeypatch.setattr(tools.approval,'register_gateway_notify',lambda *a:None)
    monkeypatch.setattr(tools.approval,'unregister_gateway_notify',lambda *a:None)
    monkeypatch.setattr(runs,'_make_approval_notify',lambda *a,**k:lambda *x:None)
    monkeypatch.setattr(runs,'_retire_live_run',lambda *a:None)
    monkeypatch.setattr(runs,'_unregister_approval_notify',lambda *a:None)
    observed=[]
    states=[]
    provider=None
    def create(**kwargs):
        nonlocal provider
        observed.append(('create',gate.api_admission.get()))
        provider=provider_module.HonchoMemoryProvider()
        provider.initialize('s1',platform='api_server',agent_context='primary',gateway_session_key='webui:s1')
        def converse(**kwargs):
            assert provider is not None
            observed.append(('executor',gate.api_admission.get()))
            assert bool(provider._session_key)==authorized
            if authorized: assert provider._session_key.startswith('moss-webui-')
            else: assert provider.get_tool_schemas()==[]
            return {'final_response':'unit-model-result'}
        return SimpleNamespace(run_conversation=converse,session_id='s1')
    adapter=SimpleNamespace(_profile_scope=lambda _:contextlib.nullcontext(),
                            _bind_api_server_session=lambda **k:[],_create_agent=create,
                            _make_run_event_callback=lambda *a:lambda *x:None,
                            _set_run_status=lambda *a,**k:states.append(a[1]),
                            _stopping_run_ids=set(),_active_run_agents={},_run_streams={})
    api=SimpleNamespace(_redact_api_error_text=str,_ProviderAuthResolutionError=RuntimeError,
                        _publish_turn_process_ownership=lambda *a:None,
                        _clear_turn_process_ownership=lambda *a:None)
    admission={'principal':'Rodolfo','session_id':'s1','profile':'default','surface':'webui'} if authorized else None
    async def exercise():
        launch=runs._RunLaunch(owner=adapter,run_id='unit-run',queue=asyncio.Queue(),session_id='s1',
                               gateway_session_key='webui:s1',declared_selected=False,user_message='test-only',
                               conversation_history=[],session_history_delivery=False,
                               agent_kwargs={'room_dispatch':None},request_profile='default',
                               browser_control_principal='',browser_control_transport_family='',
                               memory_admission=admission)
        # Ambient request context is already gone: only the launch snapshot can authorize.
        assert gate.api_admission.get() is None
        await runs._execute_run(adapter,launch,_api_server=api)
        assert gate.api_admission.get() is None
    asyncio.run(exercise())
    assert observed==[('create',admission),('executor',admission)]
    assert states[-1]=='completed'
    if authorized:
        assert provider is not None
        # A delayed session initialization retry cannot rename the conversation
        # after the request ContextVar has been cleared.
        assert provider._resolve_session_key(cfg,'rotated-transcript',**provider._lazy_init_kwargs)==provider._session_key
