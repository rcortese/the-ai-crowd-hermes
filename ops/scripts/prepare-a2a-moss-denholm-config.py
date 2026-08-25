#!/usr/bin/env python3
"""Stage the exact runtime-config delta for A2A phase 1.

Default mode is read-only.  ``--apply`` writes atomically and copies each
preimage into the caller-supplied approved backup directory.
"""
from __future__ import annotations

import argparse
import shutil
import os
import stat
import tempfile
from pathlib import Path

MARKER = "# THE-AI-CROWD A2A MOSS-DENHOLM PHASE-1\n"
MOSS_A2A = """\n# THE-AI-CROWD A2A MOSS-DENHOLM PHASE-1
a2a:
  outbound_trusted_peers:
  - denholm
a2a_agents:
  denholm:
    url: http://denholm:9900
    auth:
      type: bearer
      token: ${MOSS_TO_DENHOLM_A2A_TOKEN}
    timeout: 120
"""


def one(text: str, old: str, new: str, label: str) -> str:
    if text.count(old) != 1:
        raise ValueError(f"{label}: expected one known preimage")
    return text.replace(old, new, 1)


def moss_direct_a2a_schema(text: str) -> str:
    """Keep the mandatory Moss→Denholm caller tool directly model-visible."""
    enabled = "tools:\n  tool_search:\n    enabled: auto\n"
    disabled = "tools:\n  tool_search:\n    enabled: off\n"
    if disabled in text:
        return text
    return one(text, enabled, disabled, "Moss direct A2A schema")


def moss_candidate(text: str) -> str:
    if MARKER in text or "outbound_trusted_peers:\n  - denholm" in text:
        return moss_direct_a2a_schema(text)
    text = one(text, "toolsets:\n- hermes-cli\n- persona\n", "toolsets:\n- hermes-cli\n- persona\n- a2a\n", "Moss toolsets")
    text = one(text, "  - persona\n  cli:\n", "  - persona\n  - a2a\n  cli:\n", "Moss api_server toolsets")
    text = one(text, "  - persona\n  cron:\n", "  - persona\n  - a2a\n  cron:\n", "Moss cli toolsets")
    text = one(text, "platform_toolsets:\n", "plugins:\n  enabled:\n  - a2a-platform\n  disabled: []\nplatform_toolsets:\n", "Moss plugin block")
    return moss_direct_a2a_schema(text + MOSS_A2A)

def denholm_inbound_platform(text: str) -> str:
    platform = "platforms:\n  a2a:\n    enabled: true\n"
    if platform in text:
        return text
    return text + "\n" + platform


def denholm_candidate(text: str) -> str:
    if MARKER in text:
        return denholm_inbound_platform(text)
    text = one(text, "toolsets:\n  - hermes-cli\n  - persona\n", "toolsets:\n  - hermes-cli\n  - persona\n  - a2a\n", "Denholm toolsets")
    text = one(text, "    - hermes-lcm\n", "    - hermes-lcm\n    - a2a-platform\n", "Denholm plugin block")
    text = one(text, "    - persona\n  api_server:\n", "    - persona\n    - a2a\n  api_server:\n", "Denholm cli toolsets")
    text = one(text, "    - persona\n  cron:\n", "    - persona\n    - a2a\n  cron:\n", "Denholm api_server toolsets")
    return denholm_inbound_platform(text + "\n" + MARKER)

def write_atomic(path: Path, content: str, backup_dir: Path, backup_name: str) -> None:
    backup_dir.mkdir(parents=True, exist_ok=True)
    backup = backup_dir / backup_name
    if backup.exists():
        raise ValueError(f"backup already exists: {backup}")
    original_stat = path.stat()
    shutil.copy2(path, backup)
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=path.parent, delete=False) as fh:
        fh.write(content)
        tmp = Path(fh.name)
    os.chown(tmp, original_stat.st_uid, original_stat.st_gid)
    tmp.chmod(stat.S_IMODE(original_stat.st_mode))
    tmp.replace(path)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--moss-config", type=Path, required=True)
    parser.add_argument("--denholm-config", type=Path)
    parser.add_argument("--moss-only", action="store_true")
    parser.add_argument("--backup-dir", type=Path)
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    if args.apply and not args.backup_dir:
        raise SystemExit("--apply requires --backup-dir")
    if not args.moss_only and not args.denholm_config:
        raise SystemExit("--denholm-config is required unless --moss-only")
    moss_original = args.moss_config.read_text(encoding="utf-8")
    moss = moss_candidate(moss_original)
    denholm_original = ""
    denholm = ""
    if not args.moss_only:
        denholm_original = args.denholm_config.read_text(encoding="utf-8")
        denholm = denholm_candidate(denholm_original)
    if not args.apply:
        print("a2a_moss_denholm_config_preflight_ok")
        return
    moss_backup = args.backup_dir / "moss-config.yaml.pre-a2a-moss-denholm"
    if moss != moss_original:
        write_atomic(args.moss_config, moss, args.backup_dir, moss_backup.name)
    try:
        if not args.moss_only and denholm != denholm_original:
            write_atomic(
                args.denholm_config,
                denholm,
                args.backup_dir,
                "denholm-config.yaml.pre-a2a-moss-denholm",
            )
    except Exception:
        # Preserve all-or-nothing behavior when the second preimage/write fails.
        if moss_backup.exists():
            shutil.copy2(moss_backup, args.moss_config)
        raise
    print("a2a_moss_denholm_config_applied")


if __name__ == "__main__":
    main()
