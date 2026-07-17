#!/usr/bin/env python3
"""Contract check for the Moss all-in-one supervisor program set."""
from __future__ import annotations

import configparser
import pathlib
import sys


config_path = pathlib.Path(sys.argv[1])
deploy_path = (
    pathlib.Path(sys.argv[2])
    if len(sys.argv) > 2
    else config_path.parents[1] / "deploy-moss-all-in-one.sh"
)
parser = configparser.ConfigParser(interpolation=None)
parser.read(config_path, encoding="utf-8")
programs = {
    section.removeprefix("program:")
    for section in parser.sections()
    if section.startswith("program:")
}

assert programs == {"moss-gateway", "moss-webui"}, programs
assert "moss-dashboard" not in programs
assert parser["program:moss-gateway"]["command"] == "/opt/hermes/.venv/bin/hermes -p moss gateway run"
assert parser["program:moss-webui"]["command"] == "/opt/hermes/.venv/bin/python /opt/hermes-webui/server.py"
deploy_script = deploy_path.read_text(encoding="utf-8")
assert "http://127.0.0.1:9119" not in deploy_script
assert "http://127.0.0.1:8787/api/dashboard/status" in deploy_script
print("moss-supervisor-dashboard-contract: PASS")
