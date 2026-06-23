from __future__ import annotations

import json
import os
import re
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

SCHEMA_VERSION = "the-ai-crowd-handoff.v1"
PERSONAS = (
    "moss",
    "jen",
    "denholm",
    "roy",
    "richmond",
    "the-elders",
    "operator",
)
OWNER_DOMAINS = (
    "technical-ops",
    "product",
    "productivity",
    "intake",
    "archiveops",
    "prepared-answer",
)
DOMAIN_OWNER_BY_DOMAIN = {
    "technical-ops": "moss",
    "product": "denholm",
    "productivity": "jen",
    "intake": "roy",
    "archiveops": "richmond",
    "prepared-answer": "the-elders",
}
HANDOFF_TYPES = (
    "incident",
    "execution_request",
    "consultation",
    "ownership_return",
    "ownership_transfer",
    "artifact_request",
    "artifact_delivery",
)
FAILURE_CLASSES = (
    "runtime_failure",
    "auth_failure",
    "integration_failure",
    "network_failure",
    "container_failure",
    "gateway_failure",
    "provider_failure",
    "policy_block",
    "root_drift",
    "delivery_failure",
    "unknown",
)
TECHNICAL_FAILURE_CLASSES = {
    "runtime_failure",
    "auth_failure",
    "integration_failure",
    "network_failure",
    "container_failure",
    "gateway_failure",
    "provider_failure",
    "root_drift",
    "delivery_failure",
}
PRIVACY_CLASSES = (
    "public",
    "internal",
    "private-metadata-only",
    "private-artifact-ref",
    "secret-forbidden",
)
RECEIPT_STATES = ("written", "observed", "notified")
DELIVERY_MODE = "shared-file"
VALID_ARTIFACT_REF_PREFIXES = (
    "private-ref:",
    "file:",
    "sha256:",
    "review:",
    "summary:",
    "test:",
    "kanban:",
)
DEFAULT_ALLOWED_CANONICAL_ROOTS = (
    Path("/mnt/hermes-shared/handoffs"),
)
REJECTED_ROOTS = (
    "/mnt/hermes-shared/kanban/the-ai-crowd",
    "/workspace/the-ai-crowd/protocol",
    "/mnt/hermes-shared/protocol",
)


def allowed_canonical_roots() -> tuple[Path, ...]:
    extra_roots = tuple(
        Path(item).expanduser().resolve()
        for item in os.environ.get("THE_AI_CROWD_HANDOFF_ALLOWED_ROOTS", "").split(os.pathsep)
        if item.strip()
    )
    return DEFAULT_ALLOWED_CANONICAL_ROOTS + extra_roots
MESSAGE_ID_RE = re.compile(r"^hac_[A-Za-z0-9_:-]{8,64}$")
CORRELATION_ID_RE = re.compile(r"^corr_[A-Za-z0-9_:-]{8,64}$")
HEX64_RE = re.compile(r"^[0-9a-f]{64}$")
ISO_UTC_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
SECRET_PATTERNS = (
    re.compile(r"authorization\s*:\s*bearer\s+\S+", re.IGNORECASE),
    re.compile(r"\bbearer\s+[A-Za-z0-9._=-]{10,}", re.IGNORECASE),
    re.compile(r"\b(api[_-]?key|client[_-]?secret|access[_-]?token|refresh[_-]?token|password)\s*[:=]\s*\S+", re.IGNORECASE),
    re.compile(r"BEGIN [A-Z ]*PRIVATE KEY"),
    re.compile(r"\bchat[_-]?id\s*[:=]\s*\d{5,}\b", re.IGNORECASE),
)


class ValidationError(ValueError):
    pass


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ")


def new_message_id() -> str:
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    return f"hac_{stamp}_{uuid.uuid4().hex[:10]}"


def new_correlation_id() -> str:
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    return f"corr_{stamp}_{uuid.uuid4().hex[:10]}"


def ensure_enum(value: str, allowed: tuple[str, ...], field: str) -> str:
    if value not in allowed:
        raise ValidationError(f"{field} must be one of {allowed}; got {value!r}")
    return value


def ensure_non_empty(value: str, field: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ValidationError(f"{field} must be a non-empty string")
    return value.strip()


def ensure_iso_utc(value: str, field: str = "created_at") -> str:
    ensure_non_empty(value, field)
    if not ISO_UTC_RE.match(value):
        raise ValidationError(f"{field} must be UTC ISO-8601 with trailing Z")
    try:
        datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as exc:
        raise ValidationError(f"{field} is not a valid timestamp: {value!r}") from exc
    return value


def ensure_identifier(value: str, field: str, pattern: re.Pattern[str]) -> str:
    ensure_non_empty(value, field)
    if not pattern.match(value):
        raise ValidationError(f"{field} has invalid format: {value!r}")
    return value


def assert_no_secrets(text: str, field: str) -> None:
    if not isinstance(text, str):
        raise ValidationError(f"{field} must be a string")
    for pattern in SECRET_PATTERNS:
        if pattern.search(text):
            raise ValidationError(f"secret-like content is forbidden in {field}")


def validate_root(root: str | Path, allow_test_root: bool = False) -> Path:
    path = Path(root).expanduser()
    if not path.is_absolute():
        raise ValidationError("root_drift: handoff root must be absolute")
    resolved = path.resolve()
    resolved_str = str(resolved)
    if "/kanban/" in resolved_str or resolved_str in REJECTED_ROOTS or resolved_str.endswith("/protocol"):
        raise ValidationError(f"root_drift: rejected handoff root {resolved_str}")
    if resolved in allowed_canonical_roots():
        return resolved
    if allow_test_root and (resolved_str.startswith("/tmp/") or resolved_str.startswith("/var/tmp/")):
        return resolved
    raise ValidationError(f"root_drift: unsupported handoff root {resolved_str}")


def route_matrix() -> dict[str, dict[str, dict[str, str]]]:
    matrix: dict[str, dict[str, dict[str, str]]] = {}
    for source in PERSONAS:
        matrix[source] = {}
        for owner_domain in OWNER_DOMAINS:
            matrix_owner = DOMAIN_OWNER_BY_DOMAIN[owner_domain]
            if owner_domain == "technical-ops":
                matrix[source][owner_domain] = {
                    "matrix_owner": matrix_owner,
                    "default_target": "moss",
                    "default_decision_owner": source,
                }
            else:
                matrix[source][owner_domain] = {
                    "matrix_owner": matrix_owner,
                    "default_target": matrix_owner,
                    "default_decision_owner": matrix_owner,
                }
    return matrix


def resolve_route(
    *,
    source_persona: str,
    owner_domain: str,
    handoff_type: str,
    failure_class: str | None = None,
    target_persona: str | None = None,
    decision_owner: str | None = None,
    return_to: str | None = None,
) -> dict[str, str]:
    ensure_enum(source_persona, PERSONAS, "source_persona")
    ensure_enum(owner_domain, OWNER_DOMAINS, "owner_domain")
    ensure_enum(handoff_type, HANDOFF_TYPES, "handoff_type")
    if failure_class is not None:
        ensure_enum(failure_class, FAILURE_CLASSES, "failure_class")
    if target_persona is not None:
        ensure_enum(target_persona, PERSONAS, "target_persona")
    if decision_owner is not None:
        ensure_enum(decision_owner, PERSONAS, "decision_owner")
    if return_to is not None:
        ensure_enum(return_to, PERSONAS, "return_to")

    matrix_owner = DOMAIN_OWNER_BY_DOMAIN[owner_domain]
    technical_failure = failure_class in TECHNICAL_FAILURE_CLASSES if failure_class else False

    if technical_failure:
        resolved_target = "moss"
        reason = "technical_failure"
        resolved_decision_owner = decision_owner or source_persona
    elif target_persona is not None:
        resolved_target = target_persona
        reason = "explicit_target"
        resolved_decision_owner = decision_owner or (source_persona if owner_domain == "technical-ops" else matrix_owner)
    else:
        resolved_target = "moss" if owner_domain == "technical-ops" else matrix_owner
        reason = "domain_owner"
        resolved_decision_owner = decision_owner or (source_persona if owner_domain == "technical-ops" else matrix_owner)

    return {
        "matrix_owner": matrix_owner,
        "target_persona": resolved_target,
        "decision_owner": resolved_decision_owner,
        "executor": resolved_target,
        "return_to": return_to or source_persona,
        "reason": reason,
    }


def build_artifact_ref(ref: dict[str, Any]) -> dict[str, Any]:
    kind = ensure_non_empty(ref.get("kind", ""), "artifact_ref.kind")
    artifact_ref = ensure_non_empty(ref.get("ref", ""), "artifact_ref.ref")
    if not artifact_ref.startswith(VALID_ARTIFACT_REF_PREFIXES):
        raise ValidationError(f"artifact_ref.ref must start with one of {VALID_ARTIFACT_REF_PREFIXES}")
    privacy_class = ensure_enum(ref.get("privacy_class", ""), PRIVACY_CLASSES, "artifact_ref.privacy_class")
    description = ref.get("description")
    if description is not None:
        assert_no_secrets(description, "artifact_ref.description")
    sha256 = ref.get("sha256")
    if sha256 is not None and not HEX64_RE.match(sha256):
        raise ValidationError("artifact_ref.sha256 must be 64 lowercase hex chars")
    built = {
        "kind": kind,
        "ref": artifact_ref,
        "privacy_class": privacy_class,
    }
    if sha256 is not None:
        built["sha256"] = sha256
    if description is not None:
        built["description"] = description
    return built


def canonical_subject(target_persona: str, source_persona: str, handoff_type: str) -> str:
    return f"a2a.v1.handoff.{target_persona}.{source_persona}.{handoff_type}"


def build_envelope(
    *,
    source_persona: str,
    owner_domain: str,
    handoff_type: str,
    summary: str,
    objective: str,
    context: str,
    idempotency_key: str,
    root: str | Path = "/mnt/hermes-shared/handoffs",
    allow_test_root: bool = False,
    failure_class: str | None = None,
    target_persona: str | None = None,
    decision_owner: str | None = None,
    executor: str | None = None,
    return_to: str | None = None,
    privacy_class: str = "private-metadata-only",
    message_id: str | None = None,
    correlation_id: str | None = None,
    created_at: str | None = None,
    source_wrapper: str | None = None,
    source_runtime: str | None = None,
    source_host: str | None = None,
    artifact_refs: list[dict[str, Any]] | None = None,
    constraints: list[str] | None = None,
    receipt_requested: bool = True,
) -> dict[str, Any]:
    summary = ensure_non_empty(summary, "summary")
    objective = ensure_non_empty(objective, "objective")
    context = ensure_non_empty(context, "context")
    idempotency_key = ensure_non_empty(idempotency_key, "idempotency_key")
    assert_no_secrets(summary, "summary")
    assert_no_secrets(objective, "objective")
    assert_no_secrets(context, "context")
    ensure_enum(privacy_class, PRIVACY_CLASSES, "privacy_class")

    created_at = ensure_iso_utc(created_at or utc_now())
    message_id = ensure_identifier(message_id or new_message_id(), "message_id", MESSAGE_ID_RE)
    correlation_id = ensure_identifier(correlation_id or new_correlation_id(), "correlation_id", CORRELATION_ID_RE)

    route = resolve_route(
        source_persona=source_persona,
        owner_domain=owner_domain,
        handoff_type=handoff_type,
        failure_class=failure_class,
        target_persona=target_persona,
        decision_owner=decision_owner,
        return_to=return_to,
    )
    if executor is not None:
        ensure_enum(executor, PERSONAS, "executor")
    executor = executor or route["executor"]

    canonical_root = validate_root(root, allow_test_root=allow_test_root)
    handoff_day = created_at[:10]
    canonical_path = canonical_root / route["target_persona"] / handoff_day / f"{message_id}.json"

    built_artifact_refs = [build_artifact_ref(item) for item in (artifact_refs or [])]
    built_constraints = []
    for entry in constraints or ["no secrets", "no raw chat ids"]:
        entry = ensure_non_empty(entry, "constraint")
        assert_no_secrets(entry, "constraint")
        built_constraints.append(entry)

    adapter_subject = canonical_subject(route["target_persona"], source_persona, handoff_type)
    envelope = {
        "schema_version": SCHEMA_VERSION,
        "message_id": message_id,
        "correlation_id": correlation_id,
        "idempotency_key": idempotency_key,
        "created_at": created_at,
        "source": {
            "persona": source_persona,
            "wrapper": source_wrapper or f"{source_persona}-handoff",
            "runtime": source_runtime or "persona",
            "host": source_host or f"the-ai-crowd-{source_persona}-1",
        },
        "target": {
            "persona": route["target_persona"],
            "delivery_mode": DELIVERY_MODE,
            "path": str(canonical_path),
        },
        "owner_domain": owner_domain,
        "handoff_type": handoff_type,
        "failure_class": failure_class,
        "decision_owner": route["decision_owner"],
        "executor": executor,
        "return_to": route["return_to"],
        "privacy_class": privacy_class,
        "summary": summary,
        "objective": objective,
        "context": context,
        "artifact_refs": built_artifact_refs,
        "constraints": built_constraints,
        "route": {
            "matrix_owner": route["matrix_owner"],
            "resolved_target": route["target_persona"],
            "reason": route["reason"],
            "canonical_root": str(canonical_root),
            "canonical_path": str(canonical_path),
        },
        "receipt": {
            "requested": bool(receipt_requested),
            "channel": "shared-file-watcher",
            "states": list(RECEIPT_STATES),
        },
        "adapter": {
            "delivery_mode": DELIVERY_MODE,
            "canonical_path": str(canonical_path),
            "a2a_subject": adapter_subject,
            "nats_subject": adapter_subject,
            "nats_msg_id": message_id,
        },
    }
    return validate_envelope(envelope, allow_test_root=allow_test_root)


def validate_envelope(payload: dict[str, Any], allow_test_root: bool = False) -> dict[str, Any]:
    required = (
        "schema_version",
        "message_id",
        "correlation_id",
        "idempotency_key",
        "created_at",
        "source",
        "target",
        "owner_domain",
        "handoff_type",
        "decision_owner",
        "executor",
        "return_to",
        "privacy_class",
        "summary",
        "objective",
        "context",
        "artifact_refs",
        "route",
        "receipt",
        "adapter",
    )
    for key in required:
        if key not in payload:
            raise ValidationError(f"missing required field: {key}")

    if payload["schema_version"] != SCHEMA_VERSION:
        raise ValidationError(f"schema_version must equal {SCHEMA_VERSION}")
    ensure_identifier(payload["message_id"], "message_id", MESSAGE_ID_RE)
    ensure_identifier(payload["correlation_id"], "correlation_id", CORRELATION_ID_RE)
    ensure_non_empty(payload["idempotency_key"], "idempotency_key")
    ensure_iso_utc(payload["created_at"])
    ensure_enum(payload["owner_domain"], OWNER_DOMAINS, "owner_domain")
    ensure_enum(payload["handoff_type"], HANDOFF_TYPES, "handoff_type")
    if payload.get("failure_class") is not None:
        ensure_enum(payload["failure_class"], FAILURE_CLASSES, "failure_class")
    ensure_enum(payload["decision_owner"], PERSONAS, "decision_owner")
    ensure_enum(payload["executor"], PERSONAS, "executor")
    ensure_enum(payload["return_to"], PERSONAS, "return_to")
    ensure_enum(payload["privacy_class"], PRIVACY_CLASSES, "privacy_class")
    assert_no_secrets(payload["summary"], "summary")
    assert_no_secrets(payload["objective"], "objective")
    assert_no_secrets(payload["context"], "context")

    source = payload["source"]
    target = payload["target"]
    if not isinstance(source, dict) or not isinstance(target, dict):
        raise ValidationError("source and target must be objects")
    ensure_enum(source.get("persona"), PERSONAS, "source.persona")
    ensure_non_empty(source.get("wrapper", ""), "source.wrapper")
    ensure_non_empty(source.get("runtime", ""), "source.runtime")
    ensure_non_empty(source.get("host", ""), "source.host")
    ensure_enum(target.get("persona"), PERSONAS, "target.persona")
    if target.get("delivery_mode") != DELIVERY_MODE:
        raise ValidationError(f"target.delivery_mode must equal {DELIVERY_MODE}")
    target_path = ensure_non_empty(target.get("path", ""), "target.path")
    path_obj = Path(target_path)
    if path_obj.suffix != ".json":
        raise ValidationError("target.path must end with .json")
    validate_root(path_obj.parents[2], allow_test_root=allow_test_root)

    route = payload["route"]
    if not isinstance(route, dict):
        raise ValidationError("route must be an object")
    ensure_enum(route.get("matrix_owner"), PERSONAS, "route.matrix_owner")
    ensure_enum(route.get("resolved_target"), PERSONAS, "route.resolved_target")
    ensure_non_empty(route.get("reason", ""), "route.reason")
    canonical_root = validate_root(route.get("canonical_root", ""), allow_test_root=allow_test_root)
    canonical_path = ensure_non_empty(route.get("canonical_path", ""), "route.canonical_path")
    if str(canonical_root) not in canonical_path:
        raise ValidationError("route.canonical_path must live under route.canonical_root")
    if canonical_path != target_path:
        raise ValidationError("route.canonical_path must equal target.path")
    if route["resolved_target"] != target["persona"]:
        raise ValidationError("route.resolved_target must equal target.persona")

    artifact_refs = payload["artifact_refs"]
    if not isinstance(artifact_refs, list):
        raise ValidationError("artifact_refs must be a list")
    payload["artifact_refs"] = [build_artifact_ref(item) for item in artifact_refs]

    constraints = payload.get("constraints", [])
    if not isinstance(constraints, list):
        raise ValidationError("constraints must be a list")
    for entry in constraints:
        ensure_non_empty(entry, "constraint")
        assert_no_secrets(entry, "constraint")

    receipt = payload["receipt"]
    if not isinstance(receipt, dict):
        raise ValidationError("receipt must be an object")
    if not isinstance(receipt.get("requested"), bool):
        raise ValidationError("receipt.requested must be boolean")
    if receipt.get("channel") != "shared-file-watcher":
        raise ValidationError("receipt.channel must equal shared-file-watcher")
    states = receipt.get("states")
    if states != list(RECEIPT_STATES):
        raise ValidationError(f"receipt.states must equal {list(RECEIPT_STATES)}")

    adapter = payload["adapter"]
    if not isinstance(adapter, dict):
        raise ValidationError("adapter must be an object")
    if adapter.get("delivery_mode") != DELIVERY_MODE:
        raise ValidationError(f"adapter.delivery_mode must equal {DELIVERY_MODE}")
    if adapter.get("canonical_path") != target_path:
        raise ValidationError("adapter.canonical_path must equal target.path")
    expected_subject = canonical_subject(target["persona"], source["persona"], payload["handoff_type"])
    if adapter.get("a2a_subject") != expected_subject:
        raise ValidationError("adapter.a2a_subject does not match canonical mapping")
    if adapter.get("nats_subject") != expected_subject:
        raise ValidationError("adapter.nats_subject does not match canonical mapping")
    if adapter.get("nats_msg_id") != payload["message_id"]:
        raise ValidationError("adapter.nats_msg_id must equal message_id")

    return payload


def emit(envelope: dict[str, Any], write: bool = False) -> dict[str, Any]:
    validated = validate_envelope(envelope, allow_test_root=True)
    if write:
        out_path = Path(validated["target"]["path"])
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(json.dumps(validated, indent=2) + "\n")
    return validated
