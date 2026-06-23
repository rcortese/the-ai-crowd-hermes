# The Elders meeting-audio private corpus Q&A

The Elders may answer meeting-content questions only after Richmond approval grants access to a private corpus.

Use `bin/the-elders-meeting-corpus-query` against:

- a private corpus directory containing `corpus-manifest.json`, `chunks.jsonl`, and `index.sqlite`;
- a Richmond `approval.json` allowing `the-elders` as consumer.

The helper writes answer text only to the private output path. stdout and shared artifacts remain status-only.

Limits remain explicit: computational interpretation only, no legal advice as definitive, and no speaker-name claims unless diarization/mapping is validated.
