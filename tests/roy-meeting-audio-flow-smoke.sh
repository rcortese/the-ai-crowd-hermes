#!/usr/bin/env sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="${TMPDIR:-/tmp}/roy-meeting-audio-flow-smoke-$$"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT
mkdir -p "$TMP"
AUDIO_CORPUS_BIN="${AUDIO_ANALYST_CORPUS_BIN:-/interns/ops/wrappers/audio-analyst-corpus}"
python3 "$ROOT/agents/public/roy/bin/roy-meeting-audio-flow" synthetic-smoke --workspace "$TMP" --audio-analyst-corpus-bin "$AUDIO_CORPUS_BIN" --speaker-gate-bin "$ROOT/agents/public/roy/bin/roy-meeting-speaker-gate" --elders-query-bin "$ROOT/agents/public/the-elders/bin/the-elders-meeting-corpus-query" > "$TMP/stdout.json"
TMP_ROOT="$TMP" python3 - <<'INNERPY'
import json, os, pathlib
root=pathlib.Path(os.environ['TMP_ROOT'])
shared=root/'shared'
final=json.loads((shared/'99-final-smoke-report.sanitized.json').read_text())
assert final['status']=='passed'
assert final['source_resolution']=='found'
assert final['initial_cache_state']=='miss'
assert final['second_cache_state']=='hit'
assert final['processing_repeated'] is False
assert final['minimal_human_speaker_question_created'] is True
assert final['speaker_identity_status']=='mapped'
assert final['speaker_name_claims_allowed'] is True
assert final['elders_answerability']=='speaker_aware_private_full_corpus'
assert final['no_leak_status']=='passed'
unmapped=json.loads((shared/'02b-roy-speaker-gate-unmapped.sanitized.json').read_text())
assert unmapped['requires_human_speaker_mapping'] is True
assert unmapped['speaker_name_claims_allowed_pre_richmond'] is False
mapped=json.loads((shared/'02d-roy-speaker-gate-mapped.sanitized.json').read_text())
assert mapped['requires_human_speaker_mapping'] is False
assert mapped['speaker_name_claims_allowed_pre_richmond'] is True
approval=json.loads((shared/'04-richmond-approval.sanitized.json').read_text())
assert approval['schema_version']=='richmond-meeting-corpus-approval/v0.2'
assert approval['speaker_identity_status']=='mapped'
assert approval['speaker_name_claims_allowed'] is True
assert 'speaker_aware_private_full_corpus' in approval['allowed_answer_modes']
assert (root/'private/roy/cases/case_synthetic_meeting/questions/speaker-map-question.private.md').is_file()
assert (root/'private/the-elders/cases/case_synthetic_meeting/answers/question-001.private.json').is_file()
for p in shared.glob('*'):
    text=p.read_text(errors='ignore')
    assert 'synthetic-meeting-audio.wav' not in text
    assert str(root) not in text
    assert 'prazo operacional mencionado' not in text
    assert 'Participant Alpha' not in text
    assert 'Participant Beta' not in text
    assert 'Participant Gamma' not in text
print(json.dumps({'status':'ok','shared_files':len(list(shared.glob('*'))),'speaker_identity_status':final['speaker_identity_status']}, sort_keys=True))
INNERPY
