#!/usr/bin/env python3
"""Deterministic structural validation for shared ADR records."""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

DECISION_STATUSES = {"proposed", "accepted", "rejected", "deprecated", "superseded", "withdrawn"}
IMPLEMENTATION_STATUSES = {"not-started", "in-progress", "partially-implemented", "implemented", "verified", "blocked", "rolled-back", "not-applicable", "unknown"}
TIERS = {"T1", "T2", "T3"}
ACTIVE = {"proposed", "accepted"}
ID_RE = re.compile(r"^TAC-[A-Z][A-Z0-9-]*-\d{4}$")
FIELD_RE = re.compile(r"^- \*\*(.+?):\*\*\s*`?(.+?)`?\s*$", re.MULTILINE)


def fields(text: str) -> dict[str, str]:
    return {name.strip(): value.strip().strip('`') for name, value in FIELD_RE.findall(text)}


def issue(code: str, path: Path, message: str) -> str:
    return f"{code}|{path.as_posix()}|{message}"


def baseline(root: Path) -> dict[str, str]:
    candidate = root / "tests/fixtures/adrs/legacy-baseline.json"
    if not candidate.is_file():
        return {}
    try:
        value = json.loads(candidate.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return {"__error__": str(exc)}
    return value if isinstance(value, dict) else {"__error__": "baseline must be an object"}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    root = args.root.resolve()
    decisions = root / "docs/decisions"
    if not decisions.is_dir():
        print(issue("ADR001", decisions, "canonical shared ADR directory is missing"))
        return 1

    legacy = baseline(root)
    if "__error__" in legacy:
        print(issue("ADR002", root, legacy["__error__"]))
        return 1
    files = sorted(p for p in decisions.glob("*.md") if p.name not in {"README.md", "template.md"})
    records: list[tuple[Path, dict[str, str]]] = []
    problems: list[str] = []
    for path in files:
        data = fields(path.read_text(encoding="utf-8"))
        rel = path.relative_to(root).as_posix()
        if rel in legacy:
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            if legacy[rel] != digest:
                problems.append(issue("ADR002", path, "legacy baseline content hash does not match"))
            records.append((path, data))
            continue
        ident = data.get("ID", "")
        if not ID_RE.fullmatch(ident) or not path.name.startswith(ident + "-"):
            problems.append(issue("ADR002", path, "new shared ADR ID or filename is invalid"))
        required = ["ID", "Decision status", "Implementation status", "Date", "Tier", "Scope", "Decision scope key", "Accountable owner", "Materially affected owners", "Acceptance outcomes"]
        missing = [key for key in required if not data.get(key)]
        if missing or data.get("Decision status") not in DECISION_STATUSES or data.get("Implementation status") not in IMPLEMENTATION_STATUSES or data.get("Tier") not in TIERS:
            problems.append(issue("ADR003", path, "missing or invalid metadata: " + ", ".join(missing)))
        if data.get("Decision status") == "accepted" and data.get("Tier") in {"T2", "T3"}:
            outcomes = data.get("Acceptance outcomes", "").lower()
            owners = [owner.strip().lower() for owner in data.get("Materially affected owners", "").split(",") if owner.strip()]
            if "pending" in outcomes or "unresolved" in outcomes or any(owner not in outcomes for owner in owners):
                problems.append(issue("ADR004", path, "accepted T2/T3 record lacks explicit outcomes for affected owners"))
        if data.get("Tier") == "T3" and (not data.get("Reserved authority") or data.get("Reserved authority") == "not-applicable" or not data.get("Independent review") or data.get("Independent review") == "not-applicable"):
            problems.append(issue("ADR005", path, "T3 requires reserved authority and independent review"))
        if data.get("Implementation status") == "verified":
            if data.get("Evidence", "none") in {"", "none"} or data.get("Verification date", "not-verified") == "not-verified" or data.get("Verifier", "not-verified") == "not-verified":
                problems.append(issue("ADR008", path, "verified record needs evidence, date, and verifier"))
        records.append((path, data))

    seen: dict[str, Path] = {}
    for path, data in records:
        if data.get("Decision status") in ACTIVE and path.relative_to(root).as_posix() not in legacy:
            key = data.get("Decision scope key", "")
            if key in seen:
                problems.append(issue("ADR006", path, f"duplicate active decision scope key also used by {seen[key].as_posix()}"))
            elif key:
                seen[key] = path

    index = decisions / "README.md"
    if not index.is_file():
        problems.append(issue("ADR009", index, "shared ADR index is missing"))
    else:
        body = index.read_text(encoding="utf-8")
        for path, data in records:
            ident = data.get("ID", "")
            if not ident:
                continue
            matches = [line for line in body.splitlines() if f"| `{ident}` |" in line]
            if len(matches) != 1 or path.name not in matches[0]:
                problems.append(issue("ADR009", index, f"index must contain exactly one resolving entry for {ident}"))

    for item in sorted(problems):
        print(item)
    if problems:
        return 1
    print(f"VALID_STRUCTURE|shared_adrs={len(records)}|root={root}")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
