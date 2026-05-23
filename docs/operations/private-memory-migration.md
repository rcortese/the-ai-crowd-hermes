# Private memory migration runbook

This runbook governs future imports into `agents/private/moss/`.

## Scope

Use this runbook only for Moss-owned, curated, versionable private state.

Out of scope:

- real `.env` files;
- credentials, auth files, tokens, cookies, OAuth/provider state;
- session state;
- caches;
- runtime databases;
- dumps and log dumps;
- bulk raw OpenClaw session exports;
- private state owned by Jen, Denholm, Richmond, Roy, or The Elders unless explicitly handed off with a decision record.

## Source classification

Every candidate source must be classified before import:

| Classification | Destination |
|---|---|
| Public contract | Public repo docs/contracts |
| Moss private versioned memory | `agents/private/moss/<category>/` |
| Other-domain private state | Owning agent/domain private location |
| Unversioned runtime state | Runtime storage only, no Git |
| Private history/archive | Private archive/quarantine until curated |
| Superseded/noise | Do not import |

## Import checklist

1. Confirm public repo has no unrelated dirty state.
2. Confirm `agents/private/moss/` is ignored by public Git.
3. Confirm private repo has no remote unless explicitly approved.
4. Create a small import batch with a single purpose.
5. Start from `agents/public/moss/private.example/import-manifest.template.md` in the private repo or private deployment notes.
6. Redact or summarize sensitive evidence.
7. Use `private-ref:*` in public cards/docs instead of sensitive private paths.
8. Run public validation.
9. Run private repo status checks.
10. Commit private import locally only after review gate approval.

## Review gate requirement

Each real import batch needs a review gate with:

- source class;
- owner;
- destination;
- redaction notes;
- never-version check;
- rollback procedure;
- evidence that no public repo tracking occurred.

## Rollback

If an import is wrong but contains no secrets:

```bash
git -C agents/private/moss revert <commit>
```

If an import may contain secrets or sensitive data:

1. Stop.
2. Do not push.
3. Preserve the original source.
4. Move the bad import to private quarantine if needed.
5. Rewrite only the private repo history after explicit human approval.

Public repo rollback remains normal Git revert because it must never contain private imports.
