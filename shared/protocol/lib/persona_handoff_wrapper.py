from __future__ import annotations

import argparse
import importlib.util
import json
import os
import sys
from pathlib import Path
from types import ModuleType

REJECTED_ROOT_HINTS = (
    "/mnt/hermes-shared/kanban/the-ai-crowd",
    "/workspace/the-ai-crowd/protocol",
    "/mnt/hermes-shared/protocol",
)


def _candidate_library_paths(wrapper_path: Path) -> list[Path]:
    candidates: list[Path] = []
    override = os.environ.get("THE_AI_CROWD_HANDOFF_LIB")
    if override:
        candidates.append(Path(override).expanduser())
    candidates.append(wrapper_path.resolve().parents[4] / "shared/protocol/lib/the_ai_crowd_handoff.py")
    candidates.append(Path("/mnt/hermes-shared/protocol/lib/the_ai_crowd_handoff.py"))
    seen: set[str] = set()
    unique: list[Path] = []
    for item in candidates:
        key = str(item)
        if key not in seen:
            unique.append(item)
            seen.add(key)
    return unique


def load_protocol_module(wrapper_path: Path) -> ModuleType:
    checked: list[str] = []
    for candidate in _candidate_library_paths(wrapper_path):
        checked.append(str(candidate))
        if not candidate.exists():
            continue
        spec = importlib.util.spec_from_file_location("the_ai_crowd_handoff", candidate)
        if spec is None or spec.loader is None:
            continue
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module
    raise SystemExit(
        "ERROR: canonical handoff library not found; checked: " + ", ".join(checked)
    )


def build_emit_parser(*, prog: str, description: str) -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog=prog, description=description)
    subparsers = parser.add_subparsers(dest="command", required=True)

    emit_parser = subparsers.add_parser("emit", help="build and optionally write a canonical handoff envelope")
    emit_parser.add_argument("--target", required=True)
    emit_parser.add_argument("--owner-domain", required=True)
    emit_parser.add_argument("--handoff-type", required=True)
    emit_parser.add_argument("--summary", required=True)
    emit_parser.add_argument("--objective", required=True)
    emit_parser.add_argument("--context", required=True)
    emit_parser.add_argument("--idempotency-key", required=True)
    emit_parser.add_argument("--failure-class")
    emit_parser.add_argument("--decision-owner")
    emit_parser.add_argument("--executor")
    emit_parser.add_argument("--return-to")
    emit_parser.add_argument("--privacy-class", default="private-metadata-only")
    emit_parser.add_argument("--message-id")
    emit_parser.add_argument("--correlation-id")
    emit_parser.add_argument("--created-at")
    emit_parser.add_argument("--source-runtime")
    emit_parser.add_argument("--source-host")
    emit_parser.add_argument("--root", default="/mnt/hermes-shared/handoffs")
    emit_parser.add_argument("--allow-test-root", action="store_true")
    emit_parser.add_argument("--constraint", action="append", default=[])
    emit_parser.add_argument("--artifact-ref", action="append", default=[])
    emit_parser.add_argument("--receipt-requested", action=argparse.BooleanOptionalAction, default=True)
    mode = emit_parser.add_mutually_exclusive_group()
    mode.add_argument("--dry-run", action="store_true")
    mode.add_argument("--write", action="store_true")
    mode.add_argument("--emit", action="store_true")
    return parser


def parse_artifact_refs(module: ModuleType, raw_items: list[str]) -> list[dict[str, str]]:
    refs: list[dict[str, str]] = []
    for raw in raw_items:
        item: dict[str, str] = {}
        for pair in raw.split(","):
            if "=" not in pair:
                raise module.ValidationError(f"artifact-ref must use key=value pairs: {raw!r}")
            key, value = pair.split("=", 1)
            item[key.strip()] = value.strip()
        refs.append(item)
    return refs


def guard_root(root: str) -> None:
    normalized = root.strip()
    if normalized in REJECTED_ROOT_HINTS or "/kanban/" in normalized or normalized.endswith("/protocol"):
        raise SystemExit(f"validation error: root_drift: rejected handoff root {normalized}")


def emit_for_persona(
    *,
    persona: str,
    wrapper_name: str,
    description: str,
    wrapper_path: str | Path,
    require_proxy_for_write: bool = False,
) -> int:
    wrapper_path = Path(wrapper_path)
    parser = build_emit_parser(prog=wrapper_name, description=description)
    args = parser.parse_args()
    if args.command != "emit":
        parser.error("only the emit command is supported")

    module = load_protocol_module(wrapper_path)
    try:
        guard_root(args.root)
        write = args.write or args.emit or not args.dry_run
        if require_proxy_for_write and write and os.environ.get("THE_ELDERS_HANDOFF_ENABLE_WRITE") != "1":
            raise module.ValidationError(
                "the-elders runtime-blocked: direct shared-file emit requires a reviewed proxy/writer path"
            )
        envelope = module.build_envelope(
            source_persona=persona,
            owner_domain=args.owner_domain,
            handoff_type=args.handoff_type,
            summary=args.summary,
            objective=args.objective,
            context=args.context,
            idempotency_key=args.idempotency_key,
            root=args.root,
            allow_test_root=args.allow_test_root,
            failure_class=args.failure_class,
            target_persona=args.target,
            decision_owner=args.decision_owner,
            executor=args.executor,
            return_to=args.return_to,
            privacy_class=args.privacy_class,
            message_id=args.message_id,
            correlation_id=args.correlation_id,
            created_at=args.created_at,
            source_wrapper=wrapper_name,
            source_runtime=args.source_runtime or "persona-public-wrapper",
            source_host=args.source_host,
            artifact_refs=parse_artifact_refs(module, args.artifact_ref),
            constraints=args.constraint or None,
            receipt_requested=args.receipt_requested,
        )
        print(json.dumps(module.emit(envelope, write=write and not args.dry_run), indent=2))
        return 0
    except module.ValidationError as exc:
        print(f"validation error: {exc}", file=sys.stderr)
        return 1
