#!/usr/bin/env python3
"""Export a bounded derivative context from remote-bound clean source checkouts.

Compiled JS is supplied by the caller after focused tests/typecheck. This script
records all payload hashes; it never builds, deploys, reads credentials or cleans.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess


def git(repo, *args):
    return subprocess.check_output(["git", "-C", str(repo), *args])


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for name in ("webui", "paperclip", "compiled", "compiled-shared", "output", "recipe"):
        p.add_argument("--" + name, required=True, type=Path)
    for name in ("webui-rev", "mcp-rev", "base-image"):
        p.add_argument("--" + name, required=True)
    a = p.parse_args()
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", a.base_image):
        p.error("base-image must be an immutable image ID")
    for repo, rev in ((a.webui, a.webui_rev), (a.paperclip, a.mcp_rev)):
        if not re.fullmatch(r"[0-9a-f]{40}", rev) or git(repo, "rev-parse", "HEAD").decode().strip() != rev:
            p.error("source HEAD must match the exact requested commit")
        if git(repo, "status", "--porcelain"):
            p.error("source checkout must be clean")
        subprocess.run(["git", "-C", str(repo), "merge-base", "--is-ancestor", rev,
                        "refs/remotes/origin/integration/paperclip-external-origin"], check=True)
    a.output.mkdir(parents=True, exist_ok=False)
    manifest = {"baseImage": a.base_image, "webuiRevision": a.webui_rev, "mcpRevision": a.mcp_rev, "files": {}}

    def put(relative, data):
        target = a.output / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        target.chmod(0o644)
        manifest["files"][relative] = hashlib.sha256(data).hexdigest()

    for name in ("models", "routes", "source_turn", "gateway_chat", "paperclip_origin"):
        path = f"api/{name}.py"
        put("webui/" + path, git(a.webui, "show", a.webui_rev + ":" + path))
    for name in ("client", "config", "external-context", "format", "index", "planning-context", "stdio", "tools"):
        for suffix in (".js", ".js.map", ".d.ts", ".d.ts.map"):
            path = a.compiled / (name + suffix)
            if path.is_file():
                put("mcp/" + name + suffix, path.read_bytes())
        if not (a.compiled / (name + ".js")).is_file():
            p.error("missing compiled runtime module: " + name)
    if not a.compiled_shared.is_file():
        p.error("missing compiled shared external-origin-node.js")
    put("shared/external-origin-node.js", a.compiled_shared.read_bytes())
    for path in ("server/src/routes/issues.ts", "server/src/middleware/http-log-redaction.ts",
                 "server/src/services/external-issue-influence.ts", "packages/shared/src/external-origin-node.ts"):
        put("server-context/" + path, git(a.paperclip, "show", a.mcp_rev + ":" + path))
    put("server-context/Dockerfile", git(a.paperclip, "show", a.mcp_rev + ":docker/Dockerfile.external-origin"))
    put("Dockerfile", a.recipe.read_bytes())
    (a.output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps({"context": str(a.output), "manifest": str(a.output / "manifest.json")}))


if __name__ == "__main__":
    main()
