# Fleet release retry r2 — operator-only application

Run as root@media.lan after Moss finishes its active turn:

    bash /mnt/user/appdata/the-ai-crowd-candidates/release-20260922-r2/operator/run-visual.sh apply

Type APLICAR. Stop submitting messages/tasks until completion. The detached host worker survives SSH loss and Moss replacement; the visualizer streams progress. Reattach with the same command and `watch` instead of `apply`. `check` is read-only production preflight. `recover` is an explicit operator-only rollback for this packet's nonterminal transaction, never a retry command.

This is a NEW transaction against production HEAD 653ed9d2cd839d079c09472152051ae6b28269ba after the previous manual attempt rolled back. Do not rerun or modify the original packet. The previous source, visual logs, encrypted backups and transaction are preserved. This packet checks the exact predecessor receipt and current Compose/config hashes. It installs source into ops/releases/20260922-r2 and keeps NEW backups/state under state/private/backups/fleet-release-20260922-r2. Existing state is never overwritten. A failed retry must be reconciled before preparing another attempt.

All six immutable candidate images and original build/DB/encryption evidence are reused unchanged. Build recipe paths/manifest.json/older evidence describe their original construction, not the current retry baseline: release.json is the retry operator authority. No image rebuild is required for this host-only executor repair. Prior independent reviews do not approve this changed executor: review.json must bind a fresh approval to this release.json before apply is allowed.

Order: the-elders, richmond, denholm, jen, roy, moss. Every service gets a fresh verified encrypted snapshot first. Existing toolsets are preserved. After recreation the executor waits up to 600 seconds for Docker health AND authenticated gateway readiness/version/config verification. Only explicit transient codes are retried. Auth, version, import, policy, image identity and restart errors fail closed immediately. Rollback also waits for authenticated gateway health; it does not restore stale databases/config or erase accepted messages. The original failure is printed before rollback and a safe failure class is retained in transaction.json.

After success the human still needs to exercise WebUI approve-only-once and real Honcho memory behavior. Automated readiness is not proof of those interactive acceptance criteria.
