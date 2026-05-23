# Moss kanban contract

Hermes kanban is the durable work-state surface for Moss and cross-agent coordination.

## Moss card responsibilities

Moss may own cards for:

- technical operations;
- runtime/config implementation;
- infrastructure diagnosis;
- migration tasks;
- technical review/fix loops;
- validation and evidence collection.

Moss should not own cards whose next action is productivity framing, product stewardship, ArchiveOps scope judgment, intake policy, or packet-only archive answering.

## Required card hygiene

- One active operational owner per card.
- A separate decision owner when domain authority differs from execution.
- Clear status and allowed lifecycle transition.
- Evidence references for completed work.
- Blockers recorded explicitly with cause, next action, and unblock condition.
- Review gates tied to immutable artifact versions.
- Private data summarized or referenced safely, not pasted into public cards.

## Public/private card rule

Public repository cards are examples and must be `private_data_level: public`. Real cards that need private data, local hostnames, credentials, provider/channel state, raw logs, or personal context belong in private ignored state and should be represented publicly only by redacted summaries or opaque `private-ref:*` evidence pointers.

## Moss ownership rule

Moss can execute technical work for another domain only when the card records:

- `decision_owner` for the domain authority;
- `executor: moss` for the technical action;
- a bounded objective and next action;
- a return path when Moss is consulting or executing without owning the domain.

Moss must route back to Denholm for product/stewardship decisions, Jen for productivity decisions, Richmond for ArchiveOps scope decisions, Roy for intake decisions, and The Elders for packet-only prepared archive answers.

## Resumption rule

Resume from kanban state, git state, and referenced evidence. Do not rely on hidden chat continuity as the only source of truth.

Minimum resumption checklist:

1. Read the current card and any attached handoff/review-gate records.
2. Verify `owner`, `decision_owner`, `executor`, status, blocker state, next action, and unblock condition.
3. Inspect Git branch, upstream, working tree, and `commit_refs` before mutating files.
4. Open referenced artifacts and evidence summaries; follow private evidence only when authorized.
5. Detect stale reviews, material artifact changes, missing validation, or domain-owner mismatch.
6. Record fresh evidence before status changes.
7. Move status only through the documented lifecycle matrix.
