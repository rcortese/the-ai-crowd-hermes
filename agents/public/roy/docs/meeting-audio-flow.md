# Roy meeting-audio intake flow

When Rodolfo places a new meeting recording in `transfer`, Roy should resolve the source, open a restricted case, check source/content caches, and dispatch heavy audio processing to the Interns `audio-analyst` service.

Roy does not run `ffmpeg`, WhisperX, pyannote, or diarization locally. The versioned Intern tools are supplied by the deployment as configured wrapper paths, for example:

```text
<interns-runtime-root>/ops/wrappers/audio-analyst
<interns-runtime-root>/ops/wrappers/audio-analyst-corpus
```

Local smokes may set `AUDIO_ANALYST_CORPUS_BIN` to the mounted corpus wrapper. Production deployments should bind the concrete Interns runtime root outside the public scaffold.

The delivered harness is `bin/roy-meeting-audio-flow`. Its synthetic smoke proves:

```text
new transfer file
→ source resolution
→ initial cache miss
→ audio-analyst corpus materialization
→ speaker gate detects unmapped clusters and creates one private human mapping question
→ private human speaker map is applied
→ Roy import/cache
→ Richmond speaker-aware approval
→ The Elders private full-corpus query
→ replay cache hit
```

## Speaker-aware gate

Roy uses `bin/roy-meeting-speaker-gate` after corpus materialization.

Inputs:

- private corpus directory;
- `case_ref` and `audio_ref`;
- private output directory for operator questions;
- sanitized shared status path.

Outputs:

- shared status with only counts/flags/checksums and no speaker labels;
- if mapping is incomplete, private `speaker-map-question.private.md` asking only for cluster→participant mapping.

Rules:

- Roy must not infer real speaker identities from order, voice, topic, or transcript mentions.
- Speaker-name claims are blocked until the corpus has `speaker_identity_status: mapped` and Richmond approves speaker-aware use.
- If mapping is incomplete, Roy may still prepare cluster-aware packets and the minimal human question, but The Elders must not make speaker-name claims.

Shared artifacts are metadata/ref-only. Raw audio, transcript, segments, chunks, corpus indexes, speaker labels, and answer text stay in private case directories.
