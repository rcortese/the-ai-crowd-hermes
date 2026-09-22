# Recovery candidate — NOT RELEASED FOR ACTIVATION

This is a source-only correction candidate following a failed cutover. Do not use `run-host.sh apply`: it implements the original empty-workspace transaction, not recovery of preserved post-cutover messages. Its unchanged path and freshness guards intentionally continue refusing this candidate.

## Implemented corrections

- A valid but untyped legacy WebUI cookie receives HTTP 409 with a password reauthentication instruction before a chat turn starts when the Moss memory policy is staged. The cookie is not silently upgraded to password authentication.
- Honcho CLI status under the Moss policy uses the read-only workspace inventory endpoint. It never calls SDK get-or-create session helpers and explicitly reports ingestion and recall as unverified.
- Runtime inventory reports session ID, creation timestamp, channel classification, message count and authors without printing conversation content.
- Channel validation uses exact scoped session-ID syntax. An optional reviewed reconciliation map can exempt an exact creation-time-bound empty diagnostic session; it cannot count toward channel acceptance and any subsequent message invalidates the exemption.
- Channel ingestion PASS explicitly does not claim cross-session recall.

## Read-only commands

`python runtime_probe.py inventory` inventories the existing workspace without creating sessions. `python runtime_probe.py channels --reconciled-empty /private/path/map.json` validates ingestion using an explicitly reviewed map of empty diagnostic session IDs to their exact creation timestamps. Without a map, unexpected sessions remain errors.

## Outstanding activation gates

The existing workspace must be retained, not reset to satisfy the old empty-workspace test. A new recovery transaction must snapshot and verify existing data, support rollback without restoring the database over newer conversations, and preserve the original package and receipts. This candidate is not that transaction.

The acceptance procedure must prove distinct facts in both directions: user-origin message persisted through the authenticated channel; retrieval via Honcho in a new opposite-channel conversation without repeating the answer; evidence tying the retrieval to Honcho rather than Markdown, transcript search or current context. Connection status, a generic operator confirmation and two populated channels do not establish that result.

A proposed persistent behavioral clarification remains subject to Rodolfo's prior approval: use Honcho for personal conversational memory; keep Markdown for explicit artifacts/runbooks; distinguish provider unavailable, write verified and recall verified; never silently substitute a Markdown note for a requested Honcho memory test. No persistent identity/skill/memory instruction was changed by this candidate.
