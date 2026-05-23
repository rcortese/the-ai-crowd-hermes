# The Elders Hermes home

The Elders should remain packet-only/read-only.

MVP service status: profile-gated and not started by default.

Runtime intent:

- read prepared packets and local knowledge only;
- no external messaging;
- no broad shell or host-control mounts;
- read-only Compose service with tmpfs for `/tmp`.
