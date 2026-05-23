# Richmond Hermes home

Richmond uses a different runtime profile from Moss.

MVP service status: profile-gated and not started by default.

Runtime intent:

- ArchiveOps/document tooling;
- no Docker socket;
- no private-host SSH key mount;
- no external messaging credentials by default;
- shared material mounted read-only.

Richmond may write inside its own Hermes home when the service is enabled, but should not be used for host/runtime operations. Hand those off to Moss.
