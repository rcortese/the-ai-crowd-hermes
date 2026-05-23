# Kanban workflow

Hermes kanban is the durable interaction substrate between agents. It replaces hidden shared-session assumptions with explicit work state.

This document defines the public workflow contract. Public examples are templates only; real operational cards that contain private context belong in private state, ignored deployment storage, or redacted evidence references.

## Design model

Kanban has one primary work-state object: the **card**. Specialized objects such as handoffs and review gates are attached records that are referenced by cards.

- `kanban-card`: owns lifecycle, current owner, decision owner, executor, status, risk, artifacts, evidence, blockers, and closure.
- `handoff`: records a bounded consultation, execution request, ownership transfer, or return path between agents.
- `review-gate`: records an independent review over one immutable artifact version.

A handoff or review gate should not create a second competing lifecycle. The card remains the source of truth for the work status; attached records provide evidence for transitions.

## Card types

- `migration-task`: migration work item.
- `ops-task`: technical operation.
- `handoff`: a card whose primary purpose is cross-agent transfer or bounded consultation.
- `review-gate`: a card whose primary purpose is collecting independent review verdicts.
- `incident`: operational incident record.
- `decision-record`: architecture/product/runtime decision.
- `automation-run`: scheduled or event-driven execution record.
- `blocker`: missing decision, credential, mount, evidence, or validation.

## Statuses

`inbox`, `triaged`, `owned`, `in_progress`, `under_review`, `changes_required`, `blocked`, `waiting_user`, `approved`, `done`, `archived`.

## Lifecycle matrix

| From | Allowed next statuses | Required condition |
|---|---|---|
| `inbox` | `triaged`, `blocked`, `archived` | Initial scope is classified or rejected as out of scope. |
| `triaged` | `owned`, `waiting_user`, `blocked`, `archived` | Domain owner, decision owner, and next action are known. |
| `owned` | `in_progress`, `under_review`, `blocked`, `waiting_user`, `archived` | Accountable owner accepted the card or needs review/blocker resolution. |
| `in_progress` | `under_review`, `blocked`, `waiting_user`, `changes_required`, `done` | Work has evidence, or work cannot continue without input. |
| `under_review` | `approved`, `changes_required`, `blocked` | Review gate verdict is recorded against the artifact version. If the gate itself is stale, move the card to `changes_required` or keep it `under_review` with a stale review-gate ref. |
| `changes_required` | `in_progress`, `blocked`, `waiting_user`, `archived` | Required fixes are accepted into scope or cannot proceed. |
| `blocked` | `triaged`, `owned`, `in_progress`, `waiting_user`, `archived` | Blocking cause has owner, next action, and exit condition. |
| `waiting_user` | `triaged`, `owned`, `in_progress`, `blocked`, `archived` | User/operator input arrives or the wait is converted into a blocker. |
| `approved` | `done`, `in_progress`, `under_review`, `archived` | Approval is current; new material changes invalidate review-gate approvals and send the card back to work or review. |
| `done` | `archived`, `in_progress` | Reopen only with new evidence explaining why closure was wrong or incomplete. |
| `archived` | none | Terminal state for public workflow. |

`stale` is used on review-gate records; cards should represent stale approval as `under_review` or `changes_required` with a stale review-gate evidence ref.

## Transition authority

- The current `owner` may move work through normal execution statuses inside their domain.
- The `decision_owner` must approve changes that alter product direction, owner map, user-visible workflow, or capability policy.
- The `executor` records who is doing the current implementation step when different from the domain owner.
- Reviewers may set review-gate verdicts but do not automatically become card owners.
- The operator/user is required for irreversible external actions, credentials, provider/channel authorization, or explicit product decisions not delegated to an agent.

## Ownership and authority

Each active card has one operational `owner`, but `owner` is not the same as decision authority.

| Domain | Decision owner | Typical executor |
|---|---|---|
| Technical operations, runtime, infrastructure, validation | `moss` | `moss` |
| Product/stewardship, roadmap, agent lifecycle, role boundaries | `denholm` | `moss` only for technical implementation |
| Productivity, focus, commitments, routines | `jen` | `jen`, with Moss only for technical support |
| ArchiveOps scope, packet/refresh intent, archive-domain judgment | `richmond` | `richmond`, with Moss only for technical access mechanics |
| Intake/live-input triage | `roy` | `roy` |
| Prepared ArchiveOps packet answers | `the-elders` | `the-elders` |
| Human-only authorization | `operator` | agent executor after authorization |

Kanban must not turn Moss into a generic dispatcher. Inbox triage routes by the immediate next action and domain authority; Moss accepts cards when the next action is technical.

## Handoff semantics

Every handoff must declare `handoff_type`:

- `consultation`: asks another owner for bounded input; ownership returns to `return_to_owner`.
- `execution`: asks another owner to perform a bounded implementation step; decision authority remains with `decision_owner`.
- `ownership_transfer`: transfers the card owner because the domain changed.
- `return`: sends the card back to the prior owner after consultation/execution.

A handoff is not a silent ownership transfer. If `handoff_type` is not `ownership_transfer`, the receiving agent must not assume domain authority.

## Evidence policy

Cards should point to evidence rather than embed raw private logs:

- `commit:<sha>` for immutable Git evidence;
- `file:<public-path>` for public-safe artifacts;
- `test:<command-or-script>` for validation commands;
- `review:<review-gate-id>` for reviewer verdicts;
- `private-ref:<opaque-id>` for private evidence stored outside public git;
- `summary:<short-id>` for a redacted summary.

Public cards and examples must not contain secrets, credentials, provider/channel state, unredacted command output, LAN hostnames, private IP addresses, private filesystem paths, or dumps of conversation/session state. Evidence in public cards is summary-or-pointer only.

## Review gates

A review gate must name:

- artifact reference;
- immutable artifact version (`commit:<sha>` or `sha256:<hash>`), or `working-tree:<reason>` only for explicitly marked pre-commit review;
- reviewer lens;
- status/verdict;
- required changes when not approved;
- stale reason when a prior approval is invalidated.

Any material change to the artifact invalidates prior approval. The card must return to work or review and record the stale review-gate ref.

## Blocked and waiting states

Use `blocked` when progress needs a non-user condition: missing mount, missing credential, failed validation, missing review, unavailable dependency, or policy conflict.

Use `waiting_user` when the next unblocker is the operator input or authorization.

Both states require:

- current owner;
- blocking cause;
- next action;
- unblock condition;
- evidence or blocker refs.

## Resumption checklist

To resume work without hidden chat state:

1. Read the active card and attached handoff/review records.
2. Confirm `owner`, `decision_owner`, `executor`, status, blockers, and next action.
3. Inspect Git branch, working tree, upstream relationship, and listed `commit_refs`.
4. Read `artifact_refs` and `evidence_refs`; follow private evidence only when authorized.
5. Detect divergence: stale artifact version, dirty tree, missing evidence, changed owner boundary, or failed validation.
6. Record new evidence before changing status.
7. Move the card only through an allowed lifecycle transition.

## Public examples

Public examples live in `../../examples/`. They are deliberately fictional and public-safe. Real operational kanban state should be private or redacted before publication.

See `../../schemas/handoff.schema.json` and `../../schemas/review-gate.schema.json` for machine-readable constraints.
