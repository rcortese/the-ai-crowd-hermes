#!/usr/bin/env python3
"""Sanitize public scaffold files during history rewrites.

This versioned copy is for auditability. During a rewrite, copy it to an
absolute temporary path outside the repository before invoking git history
filtering, so the sanitizer exists while older commits are checked out.
"""

from __future__ import annotations

import os
import re
from pathlib import Path

TEXT_EXTENSIONS = {
    '.md', '.sh', '.py', '.yaml', '.yml', '.json', '.txt', '.example', '.gitignore'
}

REPLACEMENTS = [
    (re.compile(r'(?<![A-Za-z0-9_./-])/home/[a-z_][a-z0-9_-]*(?=/|$)'), '<private-home>'),
    (re.compile(r'(?<![A-Za-z0-9_.-])(?:10\.|172\.(?:1[6-9]|2[0-9]|3[0-1])\.|192\.168\.)\d{1,3}\.\d{1,3}\b'), '<private-ip>'),
    (re.compile(r"(?<=[\'\"])\d{1,3}\.\d{1,3}\.(?=[\'\"])"), '<ip-prefix>'),
    (re.compile(r'(?<![A-Za-z0-9_.-])[A-Za-z0-9-]+\.lan\b'), '<private-lan-host>'),
    (re.compile(r'(?<![A-Za-z0-9_./-])/(?:mnt|media|srv)/(?:user|disk\d+|cache|ssd|private|secrets)(?=/|$)'), '<private-storage-root>'),
    (re.compile(r'\b[Uu]nraid\b'), '<private-host-platform>'),
]


def is_text_candidate(path: Path) -> bool:
    if '.git' in path.parts:
        return False
    if not path.is_file():
        return False
    if path.suffix in TEXT_EXTENSIONS:
        return True
    if path.name.startswith('Dockerfile'):
        return True
    return False


def sanitize(path: Path) -> None:
    try:
        data = path.read_text(errors='strict')
    except UnicodeDecodeError:
        return
    except OSError:
        return
    new = data
    for pattern, replacement in REPLACEMENTS:
        new = pattern.sub(replacement, new)
    if new != data:
        path.write_text(new)


for root, dirs, files in os.walk('.'):
    if '.git' in dirs:
        dirs.remove('.git')
    root_path = Path(root)
    for name in files:
        path = root_path / name
        if is_text_candidate(path):
            sanitize(path)
