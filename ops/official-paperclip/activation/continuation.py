"""Existing API-session continuation; SUBMITTED is never COMPLETED.
Auth stays in Host.http's container-side environment. No session creation route.
"""
import re
from common import digest, need, publish, read_json, secure

MESSAGE = ('[machine TAC-246 continuation; no new authority; memory-off] '
           'The external Moss activation executor exited and was reaped. '
           'Read its hash-bound receipt, report the verified result or concrete blocker. '
           'Do not repeat lifecycle, mutate boards, restore a bridge, or infer new permission.')


def preflight(backend, plan):
    c = plan['continuation']
    need(set(c) == {'session', 'session_sha', 'memory_off_evidence'} and
         isinstance(c['session'], str) and re.fullmatch('[A-Za-z0-9_-]{8,128}', c['session']) and
         c['session'] != 'df6e86989771', 'CONTINUATION_SESSION_INPUT')
    # A hash-bound externally verified api_server AIAgent memory-off policy is
    # required; no invented per-request memory:false field is sent.
    backend.memory_off(c['memory_off_evidence'])
    caps = backend.http('GET', '/v1/capabilities')
    feature = caps['features']
    need(feature.get('run_submission') is True and feature.get('run_status') is True and
         feature.get('runs_idempotency', {}).get('supported') is True and
         feature['runs_idempotency'].get('durable') is True, 'API_CAPABILITIES')
    session = backend.http('GET', '/api/sessions/' + c['session'])
    need(session.get('object') == 'hermes.session' and
         session.get('session', {}).get('id') == c['session'] and
         session['session'].get('source') == 'api_server' and digest(session) == c['session_sha'],
         'CONTINUATION_SESSION_BINDING')
    return c


def resume(backend, plan, run, path, *, children_reaped):
    need(children_reaped is True, 'CHILD_NOT_REAPED')
    c = preflight(backend, plan)
    payload = {'session_id': c['session'], 'model': 'hermes-agent', 'input': MESSAGE}
    key = 'tac246-' + digest({'run': run, 'plan': digest(plan), 'payload': payload})
    state = {'key': key, 'payload': digest(payload), 'plan': digest(plan), 'state': 'INTENT'}
    if path.exists():
        secure(path, 0o600)
        previous = read_json(path)
        need(all(previous[k] == state[k] for k in ('key','payload','plan')), 'CONTINUATION_CAS')
        if previous['state'] == 'COMPLETED':
            return previous
        need(previous['state'] in ('INTENT', 'SUBMITTED'), 'CONTINUATION_TERMINAL')
        state = previous
    else:
        publish(path, state, exclusive=True)
    if state['state'] == 'INTENT':
        reply = backend.http('POST', '/v1/runs', payload, {'Idempotency-Key': key})
        need(reply.get('status') in ('started','queued','running','completed') and
             isinstance(reply.get('run_id'), str) and re.fullmatch('[A-Za-z0-9_-]{8,128}', reply['run_id']),
             'CONTINUATION_REJECTED')
        state.update(state='SUBMITTED', run_id=reply['run_id'])
        publish(path, state)
    deadline = backend.now() + plan['timeouts']['continuation']
    while backend.now() <= deadline:
        result = backend.http('GET', '/v1/runs/' + state['run_id'])
        need(result.get('run_id') == state['run_id'] and result.get('session_id') == c['session'],
             'CONTINUATION_RUN_BINDING')
        status = result.get('status')
        if status == 'completed':
            state.update(state='COMPLETED', response=digest(result))
            publish(path, state)
            return state
        if status in ('failed', 'cancelled', 'interrupted'):
            state.update(state='FAILED', response=digest(result))
            publish(path, state)
            raise RuntimeError('CONTINUATION_FAILED')
        need(status in ('queued','started','running','waiting_for_approval'), 'CONTINUATION_UNKNOWN_STATUS')
        backend.sleep(plan['timeouts']['interval'])
    # Keep SUBMITTED durable for explicit continuation-only reconciliation.
    raise RuntimeError('CONTINUATION_INCOMPLETE')
