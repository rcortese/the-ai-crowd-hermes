# Richmond meeting-audio corpus approval

Richmond gates meeting-audio corpus use before The Elders can answer questions.

Approval artifact fields:

- `approval_status: approved|rejected|needs_remediation`
- `approved_packet_level`
  - `L1_packet_only_orientation` — packet-only orientation; no raw transcript/corpus query.
  - `L3_private_full_corpus` — The Elders may query a complete private corpus without speaker-name claims.
  - `L3_private_full_corpus_speaker_aware` — The Elders may query a private corpus and use mapped speaker labels.
- `allowed_answer_modes`, normally including `private_full_corpus` and, only after full mapping, `speaker_aware_private_full_corpus`.
- `allowed_consumers`, normally `['the-elders']`.
- `speaker_identity_status`, copied from the private corpus manifest.
- `speaker_name_claims_allowed`, true only when `speaker_identity_status == mapped` and Richmond explicitly approves it.
- `forbidden_modes`, including raw audio access, unapproved shared transcript use, and speaker-name claims without mapping/approval.
- `corpus_ref`, provenance/checksum refs, revocation ref, and review horizon.

Richmond approval does not authorize source move/delete/archive cleanup.

External task creation requires a separate governed mutation plan and idempotency gate; Richmond approval of corpus use alone is not enough to mutate Todoist or any other external system.
