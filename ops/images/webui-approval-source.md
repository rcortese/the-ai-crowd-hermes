# WebUI approval fix: rebuild source custody

The WebUI source revision containing the empty `request_id` approval fix is
`f94874d74d8ecef09cb40e3e8fb1ccb183315c9b` in
`https://github.com/rcortese/hermes-webui.git`; its Git tree is
`febdcfcdb0c3c110c67f1c84335248a07bbb5b4f`.

The regular Moss all-in-one Dockerfile pins both values and rejects an
unexpected checkout. Roy's all-in-one builder deliberately has no default
WebUI revision: an operator must supply the revision, tree, and verified Git
archive SHA-256/size as `ROY_WEBUI_REV`, `ROY_WEBUI_TREE`,
`ROY_WEBUI_ARCHIVE_SHA256`, and `ROY_WEBUI_ARCHIVE_SIZE`. For a rebuild intended
to retain this fix, select this revision (or a verified descendant with the
same fix), compute the archive checksum and size from that exact revision, and
check the final image's `the-ai-crowd.webui-revision` label. Do not reuse the
old Roy WebUI build inputs or assume a host-side image hotfix survives rebuild.

`ops/scripts/repair_approval_v2.py` is a one-time host-side emergency repair
for the known old image preimage, not a general deployment or rebuild recipe.
It refuses changed source and requires a selected idle service and an explicit
interactive confirmation. It does not establish that the WebUI button works:
a human must exercise an actual approval. Do not re-run it on an already
patched service. Its private receipts and production Compose are not committed.

The sealed `ops/releases/20260922*` image manifests describe earlier immutable
candidates; do not rewrite them to imply they contain this correction. Any
future release packet must bind and test newly built images before rollout.
