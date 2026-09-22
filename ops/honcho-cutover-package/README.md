# Candidate: manual Honcho cutover for MEDIA

Do not treat this candidate as approved for application until the release report
states that the exact frozen package passed review and host preparation.

The operator entrypoint is `run-host.sh`; it accepts `plan`, `prepare`, `apply`,
and `verify`. It must run as root from `/root/honcho-cutover-final` on MEDIA.
No guard is disabled and no lifecycle receipt is generated or fabricated.

`plan` reads the exact live image, mounts, source hashes, repository status,
Luna binding, paired Telegram identity, WebUI password capability and empty
`moss-rodolfo` workspace. Drift is a refusal, not an automatic patch refresh.

`prepare` builds the candidate from the observed immutable image, tests it,
creates a fresh encrypted database snapshot, fully restores it into a no-network
PostgreSQL instance in tmpfs, and rehearses the selective cleanup twice. It does
not restart production services. Backups and their separately stored keys remain
on the same host; this is recovery readiness, not disaster recovery.

`apply` repeats preparation, requests APLICAR on the host terminal, installs the
policy with ingestion disabled, versions the source and canonical Compose image,
and recreates only Moss. This briefly disconnects WebUI/Telegram. The host script
survives that interruption. After health and installed-code checks it enables
memory, then waits for operator verification in both human channels. Use a NEW
password login in WebUI: old untyped cookies do not qualify. Start a new WebUI
conversation and `/new` on Telegram, submit useful real preferences, and verify
recall in new conversations across both directions. Do not send secrets.

Only after typed confirmation plus database/API channel readback does the script
enable native dreaming and retire owned predecessor data. During that final
cleanup it briefly pauses only the Honcho deriver. Other personas' messages,
conclusions and peer records are checked byte-for-byte inside the transaction.

Preserved scope: other observers' memories ABOUT Moss remain theirs. Legacy Moss
peer nodes remain inert relational tombstones where foreign keys need them.
Mixed-session summary caches are invalidated because they can contain deleted
Moss messages; surviving persona source messages and conclusions are retained.
Encrypted old backups are not erased or imported into the new workspace.

Rollback before committed cleanup disables ingestion and returns the canonical
Moss image to the observed baseline. It never restores the entire shared database
over newer work of other personas. After committed cleanup, failures such as a
Git push failure are reported without pretending the deletion was reversed.
New authorized conversations are not deleted on rollback.
If acceptance fails after ingestion, service recovery is automatic but another
apply is deliberately blocked by the fresh-workspace check. Reconcile the new
authorized memory with the operator before preparing a retry. Never erase it
automatically to make the empty-workspace check pass. This entrypoint is a
first-install transaction, not a blind retry/resume controller.

Security implementation: only the cookie-authenticated password chat handler can
mint a short-lived HMAC proof for a complete Runs request. A surface label,
turn_author, API Bearer alone, remote-persona proxy, cron, webhook or server wakeup
does not grant Honcho access. Telegram requires the exact paired owner in a DM.
Sessions are separate per conversation and channel; the two stable peers share
one workspace. Current turns only: no memory-file migration or transcript import.

Credential handling: the outbound Honcho client rejects destination drift and
redirects, and omits any JSON string in which the runtime secret detector finds
a credential. It handles known formats, assignments, URLs, keys and registered
vault values, not every possible unlabeled arbitrary string. Keep credentials
out of conversational memory input regardless.

Known scope limits: the memory proof currently supports WebUI Runs, not legacy
chat-completions fallback, OIDC, trusted-header or passkey login. Those paths stay
memory-ineligible rather than silently weakening identity. Human channel proof
is a mandatory application step, not a result fabricated by offline tests.
