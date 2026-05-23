# Moss private import manifest template

Status: template only; do not fill with real private data in the public scaffold.

Use this template in a private deployment or private Moss repo when curating OpenClaw Moss state into Hermes private memory.

## Batch metadata

```text
batch_id: private-ref:<id>
owner: Moss
purpose: <single-purpose import summary>
source_window: <date/range or source ref>
review_gate: <id or blocked>
rollback_ref: <private-ref or blocked>
public_repo_status: clean|dirty + summary
private_repo_status: clean|dirty + summary
```

## Source classification table

| Source ref | Source class | Target class | Target ref | Action | Exclusion/redaction note |
|---|---|---|---|---|---|
| `private-ref:openclaw-memory` | standing directive | Moss private versioned memory | `private-ref:moss-standing` | summarize | no raw phone/path/credential values |
| `private-ref:openclaw-operations` | operations breadcrumb | Moss private operations | `private-ref:moss-ops` | curate | include only still-useful Moss-owned ops |
| `private-ref:self-improving-openclaw` | correction/lesson | Moss private corrections | `private-ref:moss-corrections` | curate | domain-specific summary only |
| `private-ref:tools-private-infra` | private infrastructure access procedure | Moss private infrastructure runbook | `private-ref:moss-private-infra` | curate | no public hostnames/IPs/key paths |

## Never import into versioned memory

- credentials, tokens, cookies, OAuth/provider state;
- real `.env` files;
- raw session transcripts or dumps;
- caches, runtime DBs, generated logs;
- broad private archives;
- non-Moss agent private state without explicit ownership handoff;
- material whose only value is stale historical noise.

## Review checklist

- [ ] Batch has one purpose.
- [ ] Each source has an owner and classification.
- [ ] Private data is summarized or redacted where possible.
- [ ] Public files contain only `private-ref:*` references.
- [ ] Public Git does not track `agents/private/moss/`.
- [ ] Private repo has a rollback path.
- [ ] Reviewer approved the current batch evidence.

## Import result template

```text
batch_id: private-ref:<id>
status: imported|blocked|rejected
sources_processed: <count>
sources_skipped: <count + reasons>
public_refs_created: <paths or none>
private_refs_created: <private refs>
validation: <public/private checks>
review_gate: <id>
rollback: <private-ref>
```
