#!/usr/bin/env python3
"""Contract check for the Moss all-in-one supervisor program set."""
from __future__ import annotations

import configparser
import pathlib
import sys


config_path = pathlib.Path(sys.argv[1])
parser = configparser.ConfigParser(interpolation=None)
parser.read(config_path, encoding="utf-8")
programs = {
    section.removeprefix("program:")
    for section in parser.sections()
    if section.startswith("program:")
}

assert programs == {"moss-gateway", "moss-webui"}, programs
assert "moss-dashboard" not in programs
assert parser["program:moss-gateway"]["command"].endswith("hermes gateway run")
assert parser["program:moss-webui"]["command"] == "/opt/hermes/.venv/bin/python /opt/hermes-webui/server.py"
print("moss-supervisor-dashboard-contract: PASS")
