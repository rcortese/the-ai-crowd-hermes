# Public scaffold hardening

- Keep the Compose example internal-only, with no published ports, Docker socket, broad host binds or site-specific networks.
- Keep endpoint authentication, egress, private identities, image admission and credentials in reviewed private deployment configuration.
- Tool availability is not permission. Preserve persona ownership and packet-only/read-only boundaries.
- Require explicit image and existing-directory mount variables; do not distribute live image IDs or private build closures.
- Run `./tests/run-all.sh` offline and `python3 tests/privacy_guard.py --mode all` before publication.
- Check all heads/tags and tracked archive parity, not just the visible current tree. Rotate exposed credentials separately; history repair does not invalidate secrets or erase external copies.
- Store private state and backups outside public Git. Rehearse restore and rollback privately before runtime activation.

These are scaffold controls, not a statement that any production service has been hardened or migrated.
