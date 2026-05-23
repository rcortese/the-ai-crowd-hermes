# Moss review gates contract

Review gates are independent checks over a concrete artifact version.

## When to use

Use review gates for:

- architecture proposals;
- public contracts and prompts;
- runtime/capability changes;
- security-sensitive changes;
- high-impact docs or workflows;
- changes the operator explicitly asks to gate.

Review gates are required before accepting changes that alter owner boundaries, capability policy, public/private boundaries, user-visible workflow, or production runtime authority.

## Rules

- Review the same artifact version across all gates in a round.
- Use neutral reviewer prompts with artifact, evidence, criteria, and output format.
- Do not include unnecessary private context.
- A failed, unreachable, or stale reviewer does not count as approval.
- Any material artifact change invalidates prior approval for that artifact.
- Record required changes and rerun needed gates after fixes.
- Public review records contain redacted summaries and pointers, not raw private logs.

## Artifact versioning

A review gate must identify the reviewed artifact with:

- `artifact_ref`: public path or stable artifact pointer;
- `artifact_version`: `commit:<sha>` or `sha256:<content-hash>` for immutable review;
- `working-tree:<reason>` only for explicitly marked pre-commit review.

If a reviewed artifact changes materially after approval, create or update a gate with `status: stale` and a `stale_reason`, then rerun review against the new artifact version.

## Output expectation

A review gate should produce a clear verdict such as `APPROVED`, `CHANGES_REQUIRED`, or `BLOCKED`, with concise rationale and required changes when applicable.

## Fresh review loop

After implementation and commit, use an independent fresh review when the deliverable is important, public, operationally relevant, or explicitly requested.
