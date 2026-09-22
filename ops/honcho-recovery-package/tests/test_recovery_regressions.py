"""Regression fixtures only; never write to the real auth store or Honcho."""
import asyncio
import json
import sys
from types import SimpleNamespace

import httpx
import pytest
from test_memory_gate import gate, isolated
from test_runs_memory_integration import ROOT, module


def test_real_cookie_to_signed_request(monkeypatch, tmp_path):
    monkeypatch.syspath_prepend('/opt/hermes-webui')
    import api.auth as auth
    monkeypatch.setattr(auth, '_sessions', {})
    monkeypatch.setattr(auth, '_SESSIONS_FILE', tmp_path / 'sessions.json')
    monkeypatch.setattr(auth, '_signing_key', lambda: b'local-test-signing-key')
    monkeypatch.setitem(sys.modules, 'api.profiles', SimpleNamespace(get_active_profile_name=lambda: 'default'))
    monkeypatch.setitem(sys.modules, 'api.routes', SimpleNamespace(j=lambda h, body, status: (status, body)))
    executed = []
    body = b'{"session_id":"browser-test"}'

    @gate.capture_browser
    def handler(h, b):
        executed.append(True)
        return gate.sign_request(gate.web_admission.get(), body, 'browser-test', 'default')

    def browser(cookie):
        return SimpleNamespace(headers={'Cookie': 'hermes_session=' + cookie})

    old_cookie = auth.create_session()
    response = handler(browser(old_cookie), {})
    assert response[0] == 409
    assert response[1]['code'] == 'honcho_password_reauthentication_required'
    assert executed == []
    assert gate.web_admission.get() is None

    cookie = auth.create_session(auth_type='password')
    proof = handler(browser(cookie), {})[gate.HEADER]
    assert executed == [True]
    assert gate.web_admission.get() is None

    async def read():
        return body
    request = SimpleNamespace(method='POST', path='/v1/runs', read=read, headers={
        gate.HEADER: proof, 'X-Hermes-Session-Id': 'browser-test',
        'X-Hermes-Session-Key': 'webui:browser-test'})
    admission = asyncio.run(gate.request_admission(request, 'default'))
    assert admission['principal'] == 'Rodolfo'
    assert admission['surface'] == 'webui'
    with gate.admission_scope(admission):
        assert gate.eligible({'platform': 'api_server', 'agent_context': 'primary', 'session_id': 'browser-test'})
    assert not gate.eligible({'platform': 'api_server', 'agent_context': 'primary', 'session_id': 'browser-test'})


def test_status_no_sdk_session_creation(monkeypatch, capsys):
    monkeypatch.setitem(sys.modules, 'agent.moss_memory_gate', gate)
    cli = module('recovery_cli', ROOT / 'overlay/plugins/memory/honcho/cli.py')
    from plugins.memory.honcho.client import HonchoClientConfig
    cfg = HonchoClientConfig(enabled=True, base_url='http://honcho-api:8000', api_key='local',
                            workspace_id='moss-rodolfo', peer_name='Rodolfo', ai_peer='Moss',
                            session_strategy='per-session')
    monkeypatch.setattr(HonchoClientConfig, 'from_global_config', classmethod(lambda cls, **kw: cfg))
    monkeypatch.setattr(cli, '_read_config', lambda: {'enabled': True})
    monkeypatch.setattr(cli, '_show_peer_cards', lambda *a: pytest.fail('Status creates a session'))
    monkeypatch.setattr('plugins.memory.honcho.client.get_honcho_client', lambda *a: pytest.fail('Status used SDK get-or-create'))
    calls = []
    def respond(request):
        calls.append((request.method, request.url.path))
        assert request.url.path == '/v3/workspaces/list'
        return httpx.Response(200, json={'items': [{'id': 'moss-rodolfo'}], 'total': 1})
    monkeypatch.setattr(gate, 'safe_http_client', lambda *a: httpx.Client(transport=httpx.MockTransport(respond)))
    cli.cmd_status(SimpleNamespace(all=False))
    assert calls == [('POST', '/v3/workspaces/list')]
    out = capsys.readouterr().out
    assert 'read-only; no session created' in out
    assert 'Cross-session recall: NOT VERIFIED' in out


def setup_inventory(monkeypatch, rows):
    probe = module('recovery_probe', ROOT / 'runtime_probe.py')
    monkeypatch.setattr(probe, 'inventory', lambda _: rows)
    return probe


def row(surface, messages=2):
    return {'id': 'moss-' + surface + '-' + 'a' * 32, 'surface': surface,
            'created_at': 'fixture', 'message_count': messages,
            'authors': ['Moss', 'Rodolfo'] if messages else []}


def test_reconciled_empty_never_counts_as_webui(monkeypatch):
    empty = {'id': 'private', 'surface': None, 'created_at': 'fixture', 'message_count': 0, 'authors': []}
    probe = setup_inventory(monkeypatch, [row('telegram'), empty])
    with pytest.raises(ValueError, match='Unreconciled session'):
        probe.channels(None)
    with pytest.raises(ValueError, match='Channel ingestion incomplete; observed=telegram'):
        probe.channels(None, {'private': 'fixture'})


@pytest.mark.parametrize('messages,created', [(1, 'fixture'), (0, 'changed')])
def test_reconciliation_cannot_exempt_new_data(monkeypatch, messages, created):
    unknown = {'id': 'private', 'surface': None, 'created_at': created,
               'message_count': messages, 'authors': ['Moss'] if messages else []}
    probe = setup_inventory(monkeypatch, [row('telegram'), row('webui'), unknown])
    with pytest.raises(ValueError, match='Unreconciled session'):
        probe.channels(None, {'private': 'fixture'})


def test_ingestion_is_not_recall(monkeypatch, capsys):
    probe = setup_inventory(monkeypatch, [row('telegram'), row('webui')])
    probe.channels(None)
    assert 'cross_session_recall_NOT_VERIFIED' in capsys.readouterr().out


def test_inventory_rejects_incomplete_session_names(monkeypatch):
    probe = module('inventory_probe', ROOT / 'runtime_probe.py')
    def items(client, path):
        if path.endswith('/sessions/list'):
            return [{'id': 'moss-webui-forged', 'created_at': 'fixture'}]
        return []
    monkeypatch.setattr(probe, 'items', items)
    assert probe.inventory(None)[0]['surface'] is None
