#!/usr/bin/env python3
import hashlib
import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CONTRACT = json.loads((ROOT / "ops/manifests/persona-rpc-tool-contract.json").read_text())
IMAGE_LOCK = json.loads((ROOT / "ops/manifests/base-images.lock.json").read_text())
DOCS = [
    ROOT / "agents/public/denholm/AGENTS.md",
    ROOT / "agents/public/denholm/docs/operating-model.md",
    ROOT / "agents/public/denholm/docs/orchestration-card-pattern.md",
    ROOT / "agents/public/denholm/docs/product-owner-operating-contract.md",
]

assert CONTRACT == {
    "version": 1,
    "source_revision": "320070c132665077624a7506102ad13d07b1947c",
    "source_path": "tools/persona_rpc.py",
    "source_sha256": "e472451719b4a7494cf0969dc5b5b8e3aa2d60b668009b381ebdba28dd9c914e",
    "tool_name": "persona_rpc",
    "required_arguments": ["target", "question"],
    "receipt_statuses": ["ok", "error"],
}
combined = "\n".join(path.read_text() for path in DOCS)
for forbidden in ("persona_rpc.ask", "request field", "completed/refused/failed", "structured completion envelope"):
    assert forbidden not in combined, forbidden
assert 'persona_rpc(target="moss", question=<compact Orchestration Card>)' in combined
assert "`target` and `question`" in combined
assert "`status` is `ok` or `error`" in combined or "`status: ok | error`" in combined

hermes = next(item for item in IMAGE_LOCK["images"] if item["name"] == "hermes-agent")
assert hermes["source_revision"] == CONTRACT["source_revision"]
image = hermes["image"]
image_id = subprocess.run(
    ["docker", "image", "inspect", image, "--format", "{{.Id}}"],
    check=True, text=True, capture_output=True,
).stdout.strip()
assert image_id == hermes["image_id"]
source = subprocess.run(
    ["docker", "run", "--rm", "--network", "none", "--entrypoint", "/bin/cat", image, f"/opt/hermes/{CONTRACT['source_path']}"],
    check=True, capture_output=True,
).stdout
assert hashlib.sha256(source).hexdigest() == CONTRACT["source_sha256"]
schema_text = subprocess.run(
    [
        "docker", "run", "--rm", "--network", "none",
        "--entrypoint", "/opt/hermes/.venv/bin/python", image,
        "-c", "import json; from tools.persona_rpc import PERSONA_RPC_SCHEMA; print(json.dumps(PERSONA_RPC_SCHEMA, sort_keys=True))",
    ],
    check=True, text=True, capture_output=True,
).stdout
schema = json.loads(schema_text)
assert schema["name"] == CONTRACT["tool_name"]
parameters = schema["parameters"]
assert parameters["type"] == "object"
assert parameters["additionalProperties"] is False
assert parameters["required"] == CONTRACT["required_arguments"]
assert set(parameters["properties"]) == set(CONTRACT["required_arguments"])
print("persona_rpc_docs_contract_ok")
