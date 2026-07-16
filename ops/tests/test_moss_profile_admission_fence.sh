#!/usr/bin/env bash
set -Eeuo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/webui/api"
source_root=${MOSS_WEBUI_SOURCE_ROOT:-/opt/hermes-webui}
[[ -f $source_root/server.py && -f $source_root/api/routes.py ]]
cp "$source_root/server.py" "$tmp/webui/server.py"
cp "$source_root/api/routes.py" "$tmp/webui/api/routes.py"
python3 "$repo/ops/hermes-webui-overrides/apply-moss-profile-admission-fence.py" "$tmp/webui"
python3 -m py_compile "$tmp/webui/server.py" "$tmp/webui/api/routes.py" "$tmp/webui/api/admission_fence.py"
python3 - "$tmp/webui" <<'PY'
import importlib.util
import json
import os
from pathlib import Path
import stat
import sys
import tempfile

root = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("fence", root / "api/admission_fence.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

with tempfile.TemporaryDirectory() as td:
    fence = Path(td) / "fence.json"
    os.environ["HERMES_WEBUI_ADMISSION_FENCE"] = str(fence)
    assert module.admission_fenced() is False  # configured but absent
    fence.write_text(json.dumps({"schema": "moss-webui-admission-fence/v1", "fenced": True}))
    os.chmod(fence, 0o600)
    assert module.admission_fenced() is True
    fence.write_text(json.dumps({"schema": "moss-webui-admission-fence/v1", "fenced": False}))
    assert module.admission_fenced() is False
    fence.write_text("{bad")
    assert module.admission_fenced() is True
    fence.write_text("{}")
    os.chmod(fence, 0o666)
    assert module.admission_fenced() is True
    fence.unlink()
    target = Path(td) / "target"
    target.write_text("{}")
    fence.symlink_to(target)
    assert module.admission_fenced() is True
    os.environ["HERMES_WEBUI_ADMISSION_FENCE"] = "relative/fence.json"
    assert module.admission_fenced() is True

server = (root / "server.py").read_text()
routes = (root / "api/routes.py").read_text()
assert server.count("from api.admission_fence import admission_fenced") == 1
assert server.count('"error": "admission_fenced"') == 1
assert server.index("if admission_fenced():") < server.index("if not _is_csp_report_post and not check_auth")
assert server.index("if admission_fenced():") < server.index("result = route_func(self, parsed)")
assert routes.count('"admission_fenced": admission_fenced()') == 1
PY
# Digest drift must fail before writing.
printf '\n# drift\n' >>"$tmp/webui/server.py"
if python3 "$repo/ops/hermes-webui-overrides/apply-moss-profile-admission-fence.py" "$tmp/webui" >/dev/null 2>&1; then
  echo 'digest drift unexpectedly accepted' >&2
  exit 1
fi
printf 'moss_profile_admission_fence_ok\n'
