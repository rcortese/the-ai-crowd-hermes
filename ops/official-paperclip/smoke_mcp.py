#!/usr/bin/env python3
"""Real stdio artifact smoke; every HTTP request stays in a loopback fixture.
Usage: python3 smoke_mcp.py /opt/paperclip-mcp/node_modules/.bin/paperclip-mcp-server
Can also be piped into `docker run -i ... --entrypoint python3 IMAGE - EXECUTABLE`.
"""
import json
import os
import selectors
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

COMPANY = '11111111-1111-4111-8111-111111111111'
AGENT = '22222222-2222-4222-8222-222222222222'
ISSUE = '33333333-3333-4333-8333-333333333333'
RUN_A = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
RUN_B = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
KEY = 'fixture-only-not-a-credential'


def main():
    requests = []

    class Fixture(BaseHTTPRequestHandler):
        def log_message(self, format, *args):
            pass

        def reply(self):
            length = int(self.headers.get('Content-Length', '0'))
            body = self.rfile.read(length)
            requests.append((self.command, self.path, self.headers.get('X-Paperclip-Run-Id'),
                             self.headers.get('Authorization'), body))
            if self.path == '/api/redirect':
                self.send_response(302)
                self.send_header('Location', '/outside-api')
                self.end_headers()
                return
            data = json.dumps({'fixture': True}).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        do_POST = do_GET = reply

    http = ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
    thread = threading.Thread(target=http.serve_forever, daemon=True)
    thread.start()
    env = {'PATH': os.environ.get('PATH', '/usr/local/bin:/usr/bin:/bin'),
           'PAPERCLIP_API_URL': f'http://127.0.0.1:{http.server_port}/api',
           'PAPERCLIP_API_KEY': KEY, 'PAPERCLIP_RUN_CONTEXT_MODE': 'request',
           'PAPERCLIP_COMPANY_ID': COMPANY, 'PAPERCLIP_AGENT_ID': AGENT}
    process = subprocess.Popen([sys.argv[1]], env=env, stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
    assert process.stdin is not None and process.stdout is not None and process.stderr is not None
    stdin, stdout, stderr_stream = process.stdin, process.stdout, process.stderr
    sequence = 0
    pending = b''
    selector = selectors.DefaultSelector()
    selector.register(stdout, selectors.EVENT_READ)

    def rpc(method, params, notification=False) -> Any:
        nonlocal sequence, pending
        sequence += 1
        message = {'jsonrpc': '2.0', 'method': method, 'params': params}
        if not notification:
            message['id'] = sequence
        stdin.write(json.dumps(message).encode() + b'\n')
        stdin.flush()
        if notification:
            return None
        while True:
            while b'\n' not in pending:
                assert selector.select(timeout=20), 'stdio_response_timeout'
                chunk = os.read(stdout.fileno(), 65536)
                assert chunk, 'stdio_closed_early'
                pending += chunk
            line, pending = pending.split(b'\n', 1)
            result = json.loads(line)
            if result.get('id') == sequence:
                assert 'error' not in result, result
                return result['result']

    context = lambda run: {'runId': run, 'companyId': COMPANY, 'agentId': AGENT, 'issueId': ISSUE}

    def call(name='paperclipAddComment', arguments=None, ctx=None, include=True):
        params = {'name': name, 'arguments': arguments if arguments is not None else {'issueId': ISSUE, 'body': 'fixture-only'}}
        if include:
            params['_meta'] = {'paperclip/run-context': ctx}
        return rpc('tools/call', params)

    try:
        initialized = rpc('initialize', {'protocolVersion': '2024-11-05', 'capabilities': {},
                                         'clientInfo': {'name': 'artifact-fixture', 'version': '1'}})
        assert initialized['serverInfo']['name'] == 'paperclip'
        rpc('notifications/initialized', {}, notification=True)
        tools = rpc('tools/list', {})['tools']
        names = [tool['name'] for tool in tools]
        assert len(names) == len(set(names))
        assert {'paperclipMe', 'paperclipAddComment', 'paperclipApiRequest'} <= set(names)
        assert requests == [], 'catalog_made_http_request'
        missing = call(include=False)
        assert missing.get('isError') and 'Missing paperclip/run-context' in json.dumps(missing)
        assert requests == [], 'missing_context_reached_http'
        assert call(ctx={'runId': 'invalid'}).get('isError')
        assert requests == [], 'invalid_context_reached_http'
        for run in [RUN_A, RUN_B]:
            result = call(ctx=context(run))
            assert not result.get('isError') and json.loads(result['content'][0]['text']) == {'fixture': True}
        assert [row[2] for row in requests] == [RUN_A, RUN_B]
        assert all(row[1] == f'/api/issues/{ISSUE}/comments' for row in requests)
        # No sticky context after a successful call.
        assert call(include=False).get('isError')
        assert len(requests) == 2
        before = len(requests)
        for path in ['//example.invalid/steal', '/https://example.invalid/steal', '/%2e%2e/escape', '/%2fescape', '/\\escape']:
            result = call('paperclipApiRequest', {'method': 'GET', 'path': path}, context(RUN_B))
            # Official makeTool formats REST errors as JSON text, not isError.
            assert 'API path must' in json.loads(result['content'][0]['text']).get('error', ''), path
        assert len(requests) == before, 'unsafe_path_reached_http'
        result = call('paperclipApiRequest', {'method': 'GET', 'path': '/redirect'}, context(RUN_B))
        assert 'fetch failed' in json.loads(result['content'][0]['text']).get('error', ''), 'redirect_was_followed'
        assert len(requests) == before + 1 and requests[-1][1] == '/api/redirect'
        assert all(row[3] == 'Bearer ' + KEY for row in requests)
        print(json.dumps({'status': 'PASS', 'toolCount': len(tools), 'fixtureHttpRequests': len(requests),
                          'missingContextHttpRequests': 0, 'invalidContextHttpRequests': 0,
                          'originEscapeHttpRequests': 0, 'redirectFollowed': False,
                          'distinctRunHeaders': [RUN_A, RUN_B], 'productionEffects': 0}))
    finally:
        stdin.close()
        try:
            code = process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
            raise AssertionError('stdio_did_not_exit_on_eof')
        stderr = stderr_stream.read().decode()
        http.shutdown()
        http.server_close()
        thread.join(timeout=5)
        selector.close()
        assert code == 0, (code, stderr)
        assert not stderr, stderr


if __name__ == '__main__':
    main()
