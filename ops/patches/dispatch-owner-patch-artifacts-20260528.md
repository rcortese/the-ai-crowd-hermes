# Dispatch-owner patch artifacts — 2026-05-28

These files preserve the reviewed dispatch-owner repair artifacts used for the
The AI Crowd pinned-fork workflow. They are operational patch bundles, not live
runtime state or secrets.

## Files

| Path | SHA256 | Notes |
|---|---|---|
| `ops/patches/hermes-kanban-dispatch-owner-current.patch` | `37f2d195cc174c7eecb927326f26070aee94b601cf6dcba627110a18c8030de0` | Text patch for Hermes Agent dispatch-owner support and tests. |
| `ops/patches/webui-kanban-dispatch-owner-overlay.tgz` | `20f1d64a57173d9afd739582e1189c36e85496f11855cbb4e6d79a716b0cca43` | Binary WebUI overlay bundle. Commit is intentional because it preserves the exact reviewed overlay payload. |

## Tarball contents

Validated with `tar -tvzf ops/patches/webui-kanban-dispatch-owner-overlay.tgz`.
The archive contains only relative paths under `webui-overlay/`:

```text
drwxr-xr-x hermes/users      0 2026-05-28 22:30 webui-overlay/
drwxr-xr-x hermes/users      0 2026-05-28 22:30 webui-overlay/api/
-rw-r--r-- hermes/users  55907 2026-05-28 19:32 webui-overlay/api/kanban_bridge.py
drwxr-xr-x hermes/users      0 2026-05-28 22:30 webui-overlay/static/
-rw-r--r-- hermes/users 372699 2026-05-28 22:16 webui-overlay/static/panels.js
drwxr-xr-x hermes/users      0 2026-05-28 22:30 webui-overlay/tests/
-rw-r--r-- hermes/users  53527 2026-05-28 19:33 webui-overlay/tests/test_kanban_bridge.py
-rw-r--r-- hermes/users   3728 2026-05-28 19:32 webui-overlay/tests/test_kanban_bridge_dispatch_owner.py
-rw-r--r-- hermes/users   2292 2026-05-28 19:27 webui-overlay/tests/test_kanban_owner_ui_behavior.py
-rw-r--r-- hermes/users   2354 2026-05-28 19:27 webui-overlay/tests/test_kanban_owner_patch_semantics.py
```

## Safety notes

- Do not extract this tarball over a live checkout without first validating its
  hash and listing.
- Do not treat it as source of truth after the corresponding pinned fork commits
  supersede it; keep it only as evidence/rollback material for the repair run.
