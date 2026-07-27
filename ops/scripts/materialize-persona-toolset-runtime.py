#!/usr/bin/env python3
"""Materialize the Persona A2A toolset in Hermes' configurable-toolset catalog.

The A2A Hermes candidate defines ``persona`` in toolsets.py, but older runtime
bases may not expose it through ``hermes tools`` / platform tool selection.
This exact, idempotent image-build patch closes that packaging gap.
"""
from __future__ import annotations

import argparse
from pathlib import Path

ENTRY_AFTER = '    ("cronjob",         "⏰ Cron Jobs",                 "create/list/update/pause/resume/run, with optional attached skills"),\n'
ENTRY = '    ("persona",        "🛰️ Persona A2A",              "persona_rpc (ask-only, policy-routed)"),\n'
OLD_OFF = '_DEFAULT_OFF_TOOLSETS = {"homeassistant", "spotify", "discord", "discord_admin", "video", "video_gen", "x_search"}'
NEW_OFF = '_DEFAULT_OFF_TOOLSETS = {"homeassistant", "spotify", "discord", "discord_admin", "video", "video_gen", "x_search", "persona"}'


def patch(root: Path) -> None:
    path = root / 'hermes_cli' / 'tools_config.py'
    text = path.read_text()
    if ENTRY not in text:
        if ENTRY_AFTER not in text:
            raise SystemExit('persona toolset patch anchor missing')
        text = text.replace(ENTRY_AFTER, ENTRY_AFTER + ENTRY, 1)
    if NEW_OFF not in text:
        if OLD_OFF not in text:
            raise SystemExit('default-off patch anchor missing')
        text = text.replace(OLD_OFF, NEW_OFF, 1)
    path.write_text(text)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, default=Path('/opt/hermes'))
    args = parser.parse_args()
    patch(args.root)
