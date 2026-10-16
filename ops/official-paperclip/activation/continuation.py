"""Existing API-session continuation; SUBMITTED is never COMPLETED.
Auth stays in Host.http's container-side environment. No session creation route.
"""
import os
import re
from common import digest, need, publish, read_json, secure

MESSAGE = ('[machine TAC-246 continuation; no new authority; memory-off] '
           'The external Moss activation executor exited and was reaped. '
           'Read its hash-bound receipt, report the verified result or concrete blocker. '
           'Do not repeat lifecycle, mutate boards, restore a bridge, or infer new permission.')


def preflight(backend, plan, *, identity=None):
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
    row = session.get('session', {})
    # These are real _session_response fields, not an invented ownership endpoint.
    # user_id may be null: ownership is the authenticated profile API namespace,
    # plus the exact row/incarnation/provenance pinned by the initial snapshot.
    stable_keys = ('id', 'source', 'user_id', 'started_at', 'parent_session_id', 'is_internal_child')
    need(session.get('object') == 'hermes.session' and
         all(k in row for k in stable_keys) and row['id'] == c['session'] and
         row['source'] == 'api_server' and row['is_internal_child'] is False and
         row['started_at'] is not None, 'CONTINUATION_SESSION_BINDING')
    stable = digest({k: row[k] for k in stable_keys})
    need((digest(session) == c['session_sha'] if identity is None else stable == identity),
         'CONTINUATION_SESSION_BINDING')
    return stable


def resume(backend, plan, run, path, *, children_reaped):
    need(children_reaped is True, 'CHILD_NOT_REAPED')
    c = plan['continuation']
    payload = {'session_id': c['session'], 'model': 'hermes-agent', 'input': MESSAGE}
    key = 'tac246-' + digest({'run': run, 'plan': digest(plan), 'payload': payload})
    state = {'key': key, 'payload': digest(payload), 'plan': digest(plan), 'state': 'INTENT'}
    if path.exists():
        secure(path, 0o600, os.getuid())
        previous = read_json(path)
        need(all(previous[k] == state[k] for k in ('key','payload','plan')), 'CONTINUATION_CAS')
        need(isinstance(previous.get('session_identity'), str) and
             re.fullmatch('[0-9a-f]{64}', previous['session_identity']), 'CONTINUATION_CAS')
        preflight(backend, plan, identity=previous['session_identity'])
        if previous['state'] == 'COMPLETED':
            return previous
        need(previous['state'] in ('INTENT', 'SUBMITTED'), 'CONTINUATION_TERMINAL')
        state = previous
    else:
        state['session_identity'] = preflight(backend, plan)
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
