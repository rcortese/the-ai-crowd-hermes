"""Isolated composition: authenticated Hermes API -> native MCP -> real stdio -> HTTP.

Inference and the HTTP board are explicit local fixtures, not production acceptance.
No production credentials, model calls, board writes or lifecycle operations.
Requires candidate split Hermes on PYTHONPATH, MCP SDK 2.0.0, and a
built Paperclip candidate in PAPERCLIP_CONTEXT_CANDIDATE.
"""
import asyncio
import json
import os
from pathlib import Path
import threading
import tempfile
from types import SimpleNamespace
from unittest.mock import patch

# Isolate before importing Hermes; never inspect or seed a persona runtime home.
_sandbox = tempfile.TemporaryDirectory(prefix='hermes-metadata-composition-', dir=os.environ['TMPDIR'])
os.environ['HERMES_HOME'] = str(Path(_sandbox.name)/'home')
os.environ['HERMES_DISABLE_LAZY_INSTALLS'] = '1'

from aiohttp import web
from aiohttp.test_utils import TestClient, TestServer
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client
from gateway.config import PlatformConfig
from gateway.platforms import api_server
from gateway.session_context import get_mcp_metadata
from tools import mcp_tool, mcp_tool_discovery, mcp_tool_handlers

# Deliberately fictional fixture UUIDs. They are never sent to the real board.
COMPANY = '11111111-1111-4111-8111-111111111111'
AGENT = '22222222-2222-4222-8222-222222222222'
RUNS = {name: f'{digit * 8}-{digit * 4}-4{digit * 3}-8{digit * 3}-{digit * 12}'
        for name, digit in [('first', '3'), ('second', '4'), ('successor', '5')]}
ISSUES = {name: run.replace(run[0], str(int(run[0]) + 3)) for name, run in RUNS.items()}


def result(raw):
    data = json.loads(raw)
    assert 'error' not in data, data
    return json.loads(data['result'])


async def main():
    paperclip = Path(os.environ['PAPERCLIP_CONTEXT_CANDIDATE']).resolve()
    hermes = Path(os.environ['HERMES_CONTEXT_CANDIDATE']).resolve()
    assert Path(api_server.__file__).resolve().is_relative_to(hermes)
    assert Path(mcp_tool.__file__).resolve().is_relative_to(hermes)
    assert (paperclip / 'packages/mcp-server/dist/stdio.js').is_file()
    records, state = [], {}

    async def board(request):
        payload = await request.json() if request.can_read_body else None
        records.append({'method': request.method, 'path': request.path,
                        'run': request.headers.get('X-Paperclip-Run-Id'),
                        'authorization': request.headers.get('Authorization'), 'body': payload})
        if request.method in {'PATCH', 'PUT'}:
            state[request.path] = payload
        return web.json_response(state.get(request.path, {'fixture': True}))

    board_app = web.Application()
    board_app.router.add_route('*', '/{path:.*}', board)
    async with TestServer(board_app) as recorder:
        ready, stop = threading.Event(), threading.Event()
        live = {}

        async def serve_mcp():
            try:
                env = {'PAPERCLIP_API_URL': str(recorder.make_url('/')),
                       'PAPERCLIP_API_KEY': 'local-fixture-identity',
                       'PAPERCLIP_COMPANY_ID': COMPANY, 'PAPERCLIP_AGENT_ID': AGENT,
                       'PAPERCLIP_RUN_CONTEXT_MODE': 'request'}
                params = StdioServerParameters(command='node',
                    args=[str(paperclip / 'packages/mcp-server/dist/stdio.js')], env=env)
                async with stdio_client(params) as streams:
                    async with ClientSession(*streams) as session:
                        await session.initialize()
                        catalog = await session.list_tools()
                        names = {t.name for t in catalog.tools}
                        assert {'paperclipUpdateIssue', 'paperclipUpsertIssueDocument',
                                'paperclipApiRequest'} <= names
                        live.update(session=session, loop=asyncio.get_running_loop(),
                                    server=SimpleNamespace(session=session, _rpc_lock=asyncio.Lock(),
                                                           _pending_call_context=None),
                                    catalogCount=len(names))
                        ready.set()
                        await asyncio.to_thread(stop.wait)
            except BaseException as exc:
                live['exception'] = repr(exc)
                ready.set()
                raise

        def thread_main():
            asyncio.run(serve_mcp())

        thread = threading.Thread(target=thread_main, daemon=True)
        thread.start()
        assert await asyncio.to_thread(ready.wait, 20), 'stdio startup timeout'
        assert 'exception' not in live, live
        adapter = api_server.APIServerAdapter(PlatformConfig(enabled=True, extra={'key': 'local-gateway-key'}))
        db = await adapter._ensure_session_db_async()
        assert db is not None
        db.create_session('shared-fixture-session', 'api_server')
        barrier = threading.Barrier(2)
        seen_contexts = {}
        handlers = {name: mcp_tool_handlers._make_tool_handler('paperclip', name, 10) for name in (
            'paperclipUpdateIssue', 'paperclipUpsertIssueDocument', 'paperclipGetIssue',
            'paperclipGetDocument', 'paperclipApiRequest')}

        class FixtureInference:
            def run_conversation(self, **kwargs):
                name = kwargs['user_message']
                seen_contexts[name] = get_mcp_metadata()
                if name in {'first', 'second'}:
                    barrier.wait(10)
                if name in RUNS:
                    issue = ISSUES[name]
                    result(handlers['paperclipUpdateIssue']({'issueId': issue, 'title': name}))
                    result(handlers['paperclipUpsertIssueDocument']({
                        'issueId': issue, 'key': 'report', 'body': name, 'baseRevisionId': None}))
                    assert result(handlers['paperclipGetIssue']({'issueId': issue}))['title'] == name
                    assert result(handlers['paperclipGetDocument']({'issueId': issue, 'key': 'report'}))['body'] == name
                    result(handlers['paperclipApiRequest']({
                        'method': 'PATCH', 'path': '/fixture-api/' + name,
                        'jsonBody': json.dumps({'name': name})}))
                else:
                    denied = json.loads(handlers['paperclipUpdateIssue']({
                        'issueId': ISSUES['first'], 'title': 'must-not-write'}))
                    assert 'error' in denied, denied
                return {'final_response': 'local-fixture-completed', 'messages': []}

        app = web.Application()
        app.router.add_post('/v1/runs', adapter._handle_runs)
        app.router.add_get('/v1/runs/{run_id}', adapter._handle_get_run)
        auth = {'Authorization': 'Bearer local-gateway-key'}

        async def finish(client, run_id):
            async with asyncio.timeout(20):
                while True:
                    response = await client.get('/v1/runs/' + run_id, headers=auth)
                    data = await response.json()
                    if data['status'] in {'completed', 'failed', 'cancelled'}:
                        assert data['status'] == 'completed', data
                        return
                    await asyncio.sleep(0.01)

        def context(name):
            return {'mcp': {'paperclip/run-context': {
                'runId': RUNS[name], 'companyId': COMPANY, 'agentId': AGENT, 'issueId': ISSUES[name]}}}

        try:
            with patch.object(mcp_tool, '_mcp_loop', live['loop']), \
                 patch.object(mcp_tool_discovery, '_get_connected_server_for_call', lambda _: live['server']), \
                 patch.object(mcp_tool, '_server_error_counts', {}), \
                 patch.object(adapter, '_create_agent', lambda **_: FixtureInference()):
                async with TestClient(TestServer(app)) as client:
                    ids = []
                    for name in ('first', 'second'):
                        r = await client.post('/v1/runs', headers=auth, json={
                            'input': name, 'session_id': 'shared-fixture-session', 'metadata': context(name)})
                        assert r.status == 202, await r.text()
                        ids.append((await r.json())['run_id'])
                    await asyncio.gather(*(finish(client, rid) for rid in ids))
                    for name, metadata in [('successor', context('successor')), ('missing', None),
                            ('malformed', {'mcp': {'paperclip/run-context': {'runId': 'not-a-uuid'}}}),
                            ('wrong-identity', {'mcp': {'paperclip/run-context': dict(
                                context('first')['mcp']['paperclip/run-context'], agentId=COMPANY)}})]:
                        body = {'input': name, 'session_id': 'shared-fixture-session'}
                        if metadata is not None:
                            body['metadata'] = metadata
                        before = len(records)
                        r = await client.post('/v1/runs', headers=auth, json=body)
                        assert r.status == 202, await r.text()
                        await finish(client, (await r.json())['run_id'])
                        if name not in RUNS:
                            assert len(records) == before, name
        finally:
            stop.set()
            await asyncio.to_thread(thread.join, 10)
            assert not thread.is_alive(), 'stdio/session cleanup incomplete'
        assert get_mcp_metadata() is None
        assert seen_contexts['missing'] is None
        assert len(records) == 15, records
        for name, run in RUNS.items():
            own = [r for r in records if ISSUES[name] in r['path'] or r['path'].endswith('/' + name)]
            assert len(own) == 5, own
            assert all(r['authorization'] == 'Bearer local-fixture-identity' for r in own)
            assert all(r['run'] == run for r in own if r['method'] != 'GET'), own
            assert seen_contexts[name] == context(name)['mcp']
        assert 'exception' not in live, live
        print(json.dumps({'composition': 'authenticated API -> executor -> native MCP -> stdio -> HTTP fixture',
                          'catalogObserved': live['catalogCount'], 'httpRequests': len(records),
                          'overlapIsolation': True, 'successorIsolation': True,
                          'taskDocumentApiWritesAndReadback': True,
                          'missingMalformedWrongIdentityNoHttp': True,
                          'productionWrites': 0, 'inference': 'explicit local fixture',
                          'stdioCleanupVerified': True}))


if __name__ == '__main__':
    try:
        asyncio.run(main())
    finally:
        _sandbox.cleanup()
