# Todoist Model

This document defines the canonical local interpretation of Todoist structure inside the Jen workspace.

It does not make Todoist the planning architecture.
It defines how Jen should interpret Todoist constructs without collapsing horizon, context, and date semantics.

## Purpose

Use this document when Jen needs a stable local model for reading or reasoning about Todoist.
Do not use it as authority over Todoist task state itself.

## Scope

This document covers only the generic semantic interpretation of Todoist constructs used by Jen:
- horizon buckets
- projects or execution contexts
- due dates
- recurring due dates
- special support labels

Rodolfo-specific labels, buckets, and conventions belong in `../../profile/integrations.md`.

Operational adapter behavior belongs in `docs/references/todoist-ops-contract.md`.
Historical interpretation and prior analyses belong in `docs/archive/` when worth keeping in the workspace; otherwise git history is sufficient.

## Canonical interpretation

- Todoist is the execution layer, not the planning architecture.
- Projects are not deadlines.
- For obligations, `due` is the intended execution/surfacing date. If the obligation repeats, `due` carries the recurrence.
- `deadline` is the current-cycle hard cutoff when Todoist exposes it and Jen can verify it; it should normally be on or after the intended execution `due` date.
- Due date, deadline, horizon, project/context, and labels are independent axes and should not be collapsed into one another.
- Fixed due dates are mainly used to surface tasks into Today when there is a real date or a deliberate day-level work intention.
- Recurring due dates represent real-world cadence or intended execution cadence, but cadence is not automatically moral debt or a hard deadline.
- For recurring hard obligations, keep recurrence in `due` and compute the current-cycle `deadline` from the current `due.date` plus explicit policy; do not infer a next deadline from the previous `deadline.date`, and fail closed if the computed deadline would precede the intended execution date.
- Never overwrite a recurring due date with a fixed/non-recurring date as part of soft-deadline cleanup. If a recurring task needs attention today, preserve or re-anchor the recurrence instead of replacing it with a one-off date.
- Native Todoist priorities are not a strong signal unless the profile/config layer explicitly says they are meaningful for the user.
- See `todoist-deadline-reconciliation.md` for the runtime reconciliation model that supports direct Todoist app use.

## Due-date semantics

A provider/raw Todoist overdue or past-date result is `past_due_raw`: a task has a due date before today or Todoist presents it as overdue. `past_due_raw` is a date signal, not yet a behavioral conclusion that Rodolfo is late.

Before Jen mentions Todoist due, overdue, or past-date items in user-facing guidance, classify each surfaced item as one of the following categories. Use `bin/jen-todoist-due-semantics` as the executable classification surface when live due-window or task-like JSON evidence is available:

- `hard_deadline`: a real-world deadline or commitment with external consequence, such as bills, appointments, legal/financial dates, or promised delivery dates. Action: do it, renegotiate it, reschedule it explicitly, or set/verify `deadline` when supported. Use "late", "overdue", or "atrasado" only when this classification is established.
- `recurring_maintenance`: a cadence of care or upkeep, such as household maintenance, pet care, backups, or recurring review. Action: choose the next viable occurrence or re-anchor the cadence; treat missed instances as maintenance drift, not blame.
- `recurring_hard_obligation`: a recurring intended-execution cadence for an obligation with external consequence. Action: preserve recurrence in `due`; compute/read/update current-cycle `deadline` from the current `due.date` and explicit rule, or ask when not computable.
- `soft_surface`: a date used to bring work back into current attention. Action: decide whether to keep it today, move it to the configured near-horizon bucket such as `Esta Semana`, or remove the due date. Do not treat it as proof that the task became late after midnight.
- `ambiguous`: insufficient evidence to classify the date semantics. Action: ask one focused question or suggest a short review; use neutral wording until the kind is clear.

When semantics are unclear, use neutral wording such as "items with past dates", "it appeared in Todoist today", or "it still has yesterday's date" instead of deadline, debt, guilt, or lateness wording.
Today and Overdue can contain hard commitments, recurring cadence, soft surfaced work, or ambiguous items; do not infer the kind from Today or Overdue alone.

## Structural interpretation

- `#` labels define horizons or buckets.
- `@` labels define projects or execution contexts, and a task may have more than one.
- Project placement expresses horizon or area, not necessarily urgency.
- Due date does not define project meaning.
- Moving a task between horizon buckets is different from assigning a real due date.
- Inbox-like capture areas mean captured but not yet refined.
- Near-horizon buckets can act as candidate pools for items that may later surface into current attention.
- Support labels can define filtered execution views that complement Today or equivalent current-attention views.
- Concrete workspace names, labels, and bucket meanings are profile/config calibration, not product policy.

## Boundary reminder

This model is a local semantic aid for Jen.
It must not become a competing planning system or override live Todoist state.
