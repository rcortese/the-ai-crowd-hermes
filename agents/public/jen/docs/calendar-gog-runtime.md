# Jen Calendar gog runtime contract

Step 2 installs `gog` in the Jen Hermes image and pins Calendar state to Jen's private runtime home.

Runtime environment:

- `GOG_HOME=/opt/data/gog`
- `GOG_KEYRING_BACKEND=file`
- `GOG_ACCOUNT=${JEN_GOOGLE_ACCOUNT:-}`
- `GOG_KEYRING_PASSWORD` is intentionally not committed or baked into the image.

Before Calendar credentials are provisioned, `gog auth doctor --check` is expected to fail closed. Calendar wrappers in later steps must not claim live Calendar readiness until the same Jen container entrypoint can pass gog auth checks. Run provisioning and validation as the Hermes runtime user, for example docker exec -u 99:100 the-ai-crowd-jen-1 gog auth doctor --check, so root-owned runtime state is not created under /opt/data/gog.
