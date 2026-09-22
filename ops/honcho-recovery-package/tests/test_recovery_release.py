"""Recovery release invariants; isolated fixtures, no production writes."""
import copy
from types import SimpleNamespace

import pytest
from test_runs_memory_integration import module, ROOT
from test_recovery_regressions import row, setup_inventory


def fresh_rows():
    rows = []
    for surface in ('telegram', 'webui'):
        for i in range(2):
            r = row(surface)
            r['id'] = f'moss-{surface}-' + str(i) * 32
            r['created_at'] = '2026-09-22T20:00:00Z'
            rows.append(r)
    return rows


def test_acceptance_requires_new_conversations(monkeypatch):
    rows = fresh_rows()
    probe = setup_inventory(monkeypatch, rows)
    probe.channels(None, since='2026-09-22T19:00:00Z')
    rows[0]['created_at'] = '2026-09-22T18:00:00Z'
    with pytest.raises(ValueError, match='two NEW'):
        probe.channels(None, since='2026-09-22T19:00:00Z')


def test_recovery_preserves_reviewed_empty_and_human_sessions(monkeypatch):
    probe = setup_inventory(monkeypatch, [])
    rows = fresh_rows() + [{'id': 'private', 'surface': None, 'created_at': probe.RECONCILED_EMPTY['private'], 'message_count': 0, 'authors': []}]
    original = copy.deepcopy(rows)
    probe.validate_origins(rows, probe.RECONCILED_EMPTY)
    assert rows == original
    rows[-1]['message_count'] = 1
    with pytest.raises(ValueError, match='Unreconciled'):
        probe.validate_origins(rows, probe.RECONCILED_EMPTY)


def test_recovery_rejects_other_authors(monkeypatch):
    probe = setup_inventory(monkeypatch, [])
    rows = fresh_rows()
    rows[0]['authors'].append('unapproved')
    with pytest.raises(ValueError, match='Unexpected author'):
        probe.validate_origins(rows, probe.RECONCILED_EMPTY)


def test_dream_rollback_does_not_require_channel_acceptance(monkeypatch):
    probe = setup_inventory(monkeypatch, [])
    workspace = {'configuration': {'dream': {'enabled': True}, 'other': 'preserved'}}
    monkeypatch.setattr(probe, 'workspace', lambda _: workspace)
    writes = []
    monkeypatch.setattr(probe, 'call', lambda *a: writes.append(a))
    probe.dreaming(None, False)
    assert workspace['configuration'] == {'dream': {'enabled': False}, 'other': 'preserved'}
    assert len(writes) == 1


def test_moss_memory_instruction_and_write_result(monkeypatch):
    provider = module('release_provider', ROOT/'overlay/plugins/memory/honcho/__init__.py')
    p = provider.HonchoMemoryProvider()
    p._config = SimpleNamespace()
    monkeypatch.setenv('AGENT_NAME', 'moss')
    text = p.system_prompt_block()
    assert 'do not substitute a Markdown file' in text
    assert 'Connectivity does not prove' in text
    p._session_key = 'fixture'
    monkeypatch.setattr(p, '_bot_turn_write_refusal', lambda: None)
    p._manager = SimpleNamespace(create_conclusion=lambda *a, **k: False)
    assert 'Failed to save' in p._tool_conclude({'conclusion': 'fixture'})
    p._manager = SimpleNamespace(create_conclusion=lambda *a, **k: True)
    assert 'Conclusion saved' in p._tool_conclude({'conclusion': 'fixture'})


def test_script_recovery_not_empty_and_backup_per_attempt():
    text = (ROOT/'run-host.sh').read_text()
    assert 'verify_fresh.sql' not in text
    assert 'verify_recovery.sql' in text
    assert 'ops/honcho-recovery-package' in text
    assert 'RECUPERACAO_CONFIRMADA' not in text
    assert 'probe channels --since' not in text
    assert 'files rollback-compose' not in text
    assert '$(date -u +%Y%m%dT%H%M%SZ)-$$' in text
