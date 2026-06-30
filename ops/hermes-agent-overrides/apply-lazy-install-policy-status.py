#!/usr/bin/env python3
"""Patch Hermes lazy-install UX to report configured vs effective policy."""

from __future__ import annotations

import importlib.util
import os
import py_compile
import sys
import types
from pathlib import Path

ROOT = Path(os.environ.get("HERMES_AGENT_DIR", "/opt/hermes"))
LAZY_TARGET = ROOT / "tools" / "lazy_deps.py"
DOCTOR_TARGET = ROOT / "hermes_cli" / "doctor.py"
STATUS_TARGET = ROOT / "hermes_cli" / "status.py"

POLICY_ANCHOR = """@dataclass(frozen=True)
class _InstallResult:
    success: bool
    stdout: str
    stderr: str


# =============================================================================
"""

POLICY_BLOCK = """@dataclass(frozen=True)
class _InstallResult:
    success: bool
    stdout: str
    stderr: str


@dataclass(frozen=True)
class LazyInstallPolicy:
    config_allow_lazy_installs: bool | None
    config_source: str
    env_disable_lazy_installs: bool
    env_disable_lazy_installs_value: str | None
    effective_lazy_installs: bool
    reason: str

    def as_dict(self) -> dict[str, Any]:
        return {
            "security.allow_lazy_installs": self.config_allow_lazy_installs,
            "config_source": self.config_source,
            "HERMES_DISABLE_LAZY_INSTALLS": self.env_disable_lazy_installs_value,
            "env_disable_lazy_installs": self.env_disable_lazy_installs,
            "effective_lazy_installs": self.effective_lazy_installs,
            "reason": self.reason,
        }

    def failure_reason(self) -> str:
        env_value = self.env_disable_lazy_installs_value
        env_display = env_value if env_value is not None else "(unset)"
        return (
            "lazy installs disabled "
            f"({self.reason}; "
            f"security.allow_lazy_installs={_policy_bool(self.config_allow_lazy_installs)}; "
            f"HERMES_DISABLE_LAZY_INSTALLS={env_display}; "
            f"effective_lazy_installs={_policy_bool(self.effective_lazy_installs)})"
        )


def _policy_bool(value: bool | None) -> str:
    if value is None:
        return "unknown"
    return "true" if value else "false"


def _coerce_policy_bool(value: Any, *, default: bool = True) -> bool:
    if isinstance(value, bool):
        return value
    if value is None:
        return default
    if isinstance(value, str):
        normalized = value.strip().lower()
        if normalized in {"1", "true", "yes", "on"}:
            return True
        if normalized in {"0", "false", "no", "off"}:
            return False
    return bool(value)


def get_lazy_install_policy() -> LazyInstallPolicy:
    # Contract: config value + env policy override -> effective runtime value.
    env_value = os.environ.get("HERMES_DISABLE_LAZY_INSTALLS")
    env_disabled = env_value == "1"

    try:
        from hermes_cli.config import load_config
        cfg = load_config()
        sec = cfg.get("security") if isinstance(cfg, dict) else {}
        if not isinstance(sec, dict):
            sec = {}
        if "allow_lazy_installs" in sec:
            config_allow = _coerce_policy_bool(sec.get("allow_lazy_installs"), default=True)
            config_source = "security.allow_lazy_installs"
        else:
            config_allow = True
            config_source = "default"
    except Exception as exc:
        config_allow = True
        config_source = f"default (config unreadable: {exc})"

    if env_disabled:
        effective = False
        reason = "disabled by environment policy"
    elif config_allow is False:
        effective = False
        reason = "disabled by config"
    else:
        effective = True
        reason = "enabled by config" if config_source == "security.allow_lazy_installs" else "enabled by default"

    return LazyInstallPolicy(
        config_allow_lazy_installs=config_allow,
        config_source=config_source,
        env_disable_lazy_installs=env_disabled,
        env_disable_lazy_installs_value=env_value,
        effective_lazy_installs=effective,
        reason=reason,
    )


# =============================================================================
"""

NEW_ALLOW_FUNC = """def _allow_lazy_installs() -> bool:
    return get_lazy_install_policy().effective_lazy_installs
"""

OLD_DISABLED_BLOCK = """    if not _allow_lazy_installs():
        raise FeatureUnavailable(
            feature, missing,
            "lazy installs disabled (security.allow_lazy_installs=false)"
        )
"""

NEW_DISABLED_BLOCK = """    lazy_policy = get_lazy_install_policy()
    if not lazy_policy.effective_lazy_installs:
        raise FeatureUnavailable(
            feature, missing,
            lazy_policy.failure_reason()
        )
"""

STATUS_HELPER = """
def _lazy_policy_bool(value) -> str:
    if value is None:
        return "unknown"
    return "true" if value else "false"


def _print_lazy_install_policy_status() -> None:
    try:
        from tools.lazy_deps import get_lazy_install_policy
        policy = get_lazy_install_policy()
    except Exception as exc:
        print(f"  Lazy installs: (could not determine: {exc})")
        return

    env_value = policy.env_disable_lazy_installs_value
    env_display = env_value if env_value is not None else "(unset)"
    print("  Lazy installs:")
    print(f"    security.allow_lazy_installs: {_lazy_policy_bool(policy.config_allow_lazy_installs)}")
    print(f"    HERMES_DISABLE_LAZY_INSTALLS: {env_display}")
    print(f"    effective_lazy_installs: {_lazy_policy_bool(policy.effective_lazy_installs)}")
    print(f"    reason: {policy.reason}")

"""

STATUS_CALL_OLD = """    print(f"  Model:        {_configured_model_label(config)}")
    print(f"  Provider:     {_effective_provider_label()}")

    # =========================================================================
"""

STATUS_CALL_NEW = """    print(f"  Model:        {_configured_model_label(config)}")
    print(f"  Provider:     {_effective_provider_label()}")
    _print_lazy_install_policy_status()

    # =========================================================================
"""

DOCTOR_HELPER = """
def _lazy_policy_bool(value) -> str:
    if value is None:
        return "unknown"
    return "true" if value else "false"


def _check_lazy_install_policy() -> None:
    try:
        from tools.lazy_deps import get_lazy_install_policy
        policy = get_lazy_install_policy()
    except Exception as exc:
        check_warn("Lazy install policy", f"(could not determine: {exc})")
        return

    detail = f"(reason: {policy.reason})"
    if policy.effective_lazy_installs:
        check_ok("Lazy installs effective", detail)
    else:
        check_warn("Lazy installs disabled", detail)
    env_value = policy.env_disable_lazy_installs_value
    env_display = env_value if env_value is not None else "(unset)"
    check_info(f"security.allow_lazy_installs: {_lazy_policy_bool(policy.config_allow_lazy_installs)}")
    check_info(f"HERMES_DISABLE_LAZY_INSTALLS: {env_display}")
    check_info(f"effective_lazy_installs: {_lazy_policy_bool(policy.effective_lazy_installs)}")
    check_info(f"reason: {policy.reason}")

"""

DOCTOR_CALL_OLD = """    for module, name in optional_packages:
        try:
            __import__(module)
            check_ok(name, "(optional)")
        except ImportError:
            check_warn(name, "(optional, not installed)")

    _section("Configuration Files")
"""

DOCTOR_CALL_NEW = """    for module, name in optional_packages:
        try:
            __import__(module)
            check_ok(name, "(optional)")
        except ImportError:
            check_warn(name, "(optional, not installed)")

    _section("Lazy Install Policy")
    _check_lazy_install_policy()

    _section("Configuration Files")
"""


def replace_once(text: str, old: str, new: str, label: str) -> tuple[str, bool]:
    if new in text:
        return text, False
    if old not in text:
        raise SystemExit(f"lazy-install-policy-status: anchor not found for {label}")
    return text.replace(old, new, 1), True


def replace_function_until(text: str, start_marker: str, end_marker: str, new: str, label: str) -> tuple[str, bool]:
    if new in text:
        return text, False
    try:
        start = text.index(start_marker)
        end = text.index(end_marker, start)
    except ValueError as exc:
        raise SystemExit(f"lazy-install-policy-status: function anchor not found for {label}: {exc}") from exc
    return text[:start] + new + text[end:], True


def patch_lazy_deps() -> bool:
    text = LAZY_TARGET.read_text()
    changed = False
    text, did = replace_once(text, POLICY_ANCHOR, POLICY_BLOCK, "lazy policy helper")
    changed |= did
    text, did = replace_function_until(
        text,
        "def _allow_lazy_installs() -> bool:",
        "\n\ndef _spec_is_safe",
        NEW_ALLOW_FUNC,
        "_allow_lazy_installs",
    )
    changed |= did
    text, did = replace_once(text, OLD_DISABLED_BLOCK, NEW_DISABLED_BLOCK, "disabled reason")
    changed |= did
    if changed:
        LAZY_TARGET.write_text(text)
        print(f"lazy-install-policy-status: patched {LAZY_TARGET}")
    return changed


def patch_status() -> bool:
    text = STATUS_TARGET.read_text()
    changed = False
    if "def _print_lazy_install_policy_status" not in text:
        text, did = replace_once(
            text,
            "\nfrom hermes_constants import is_termux as _is_termux\n",
            STATUS_HELPER + "from hermes_constants import is_termux as _is_termux\n",
            "status helper",
        )
        changed |= did
    text, did = replace_once(text, STATUS_CALL_OLD, STATUS_CALL_NEW, "status call")
    changed |= did
    if changed:
        STATUS_TARGET.write_text(text)
        print(f"lazy-install-policy-status: patched {STATUS_TARGET}")
    return changed


def patch_doctor() -> bool:
    text = DOCTOR_TARGET.read_text()
    changed = False
    if "def _check_lazy_install_policy" not in text:
        text, did = replace_once(
            text,
            "\ndef run_doctor(args):\n",
            DOCTOR_HELPER + "def run_doctor(args):\n",
            "doctor helper",
        )
        changed |= did
    if '_section("Lazy Install Policy")' not in text:
        marker = '    _section("Configuration Files")\n'
        replacement = (
            '    _section("Lazy Install Policy")\n'
            "    _check_lazy_install_policy()\n\n"
            + marker
        )
        text, did = replace_once(text, marker, replacement, "doctor call")
        changed |= did
    if changed:
        DOCTOR_TARGET.write_text(text)
        print(f"lazy-install-policy-status: patched {DOCTOR_TARGET}")
    return changed


def compile_targets() -> None:
    for target in (LAZY_TARGET, STATUS_TARGET, DOCTOR_TARGET):
        py_compile.compile(str(target), doraise=True)


def load_lazy_module():
    spec = importlib.util.spec_from_file_location("patched_lazy_deps_for_smoke", LAZY_TARGET)
    if spec is None or spec.loader is None:
        raise RuntimeError("could not load patched lazy_deps module")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def smoke_policy_helper() -> None:
    lazy_deps = load_lazy_module()
    old_env = os.environ.get("HERMES_DISABLE_LAZY_INSTALLS")
    old_config_module = sys.modules.get("hermes_cli.config")
    had_hermes_cli = "hermes_cli" in sys.modules
    old_hermes_cli = sys.modules.get("hermes_cli")
    sys.modules.setdefault("hermes_cli", types.ModuleType("hermes_cli"))
    fake_config_module = types.ModuleType("hermes_cli.config")
    fake_config_module.load_config = lambda: {"security": {"allow_lazy_installs": True}}
    sys.modules["hermes_cli.config"] = fake_config_module
    try:
        os.environ["HERMES_DISABLE_LAZY_INSTALLS"] = "1"
        policy = lazy_deps.get_lazy_install_policy()
        assert policy.config_allow_lazy_installs is True, policy
        assert policy.env_disable_lazy_installs is True, policy
        assert policy.effective_lazy_installs is False, policy
        assert policy.reason == "disabled by environment policy", policy
        assert "HERMES_DISABLE_LAZY_INSTALLS=1" in policy.failure_reason(), policy.failure_reason()
        assert lazy_deps._allow_lazy_installs() is False

        os.environ.pop("HERMES_DISABLE_LAZY_INSTALLS", None)
        fake_config_module.load_config = lambda: {"security": {"allow_lazy_installs": False}}
        policy = lazy_deps.get_lazy_install_policy()
        assert policy.config_allow_lazy_installs is False, policy
        assert policy.effective_lazy_installs is False, policy
        assert policy.reason == "disabled by config", policy

        fake_config_module.load_config = lambda: {"security": {"allow_lazy_installs": True}}
        policy = lazy_deps.get_lazy_install_policy()
        assert policy.effective_lazy_installs is True, policy
        assert policy.reason == "enabled by config", policy
    finally:
        if old_env is None:
            os.environ.pop("HERMES_DISABLE_LAZY_INSTALLS", None)
        else:
            os.environ["HERMES_DISABLE_LAZY_INSTALLS"] = old_env
        if old_config_module is None:
            sys.modules.pop("hermes_cli.config", None)
        else:
            sys.modules["hermes_cli.config"] = old_config_module
        if had_hermes_cli:
            sys.modules["hermes_cli"] = old_hermes_cli
        else:
            sys.modules.pop("hermes_cli", None)


def smoke_text_contract() -> None:
    lazy_text = LAZY_TARGET.read_text()
    status_text = STATUS_TARGET.read_text()
    doctor_text = DOCTOR_TARGET.read_text()
    required_lazy = [
        "class LazyInstallPolicy",
        "def get_lazy_install_policy",
        "disabled by environment policy",
        "effective_lazy_installs",
    ]
    required_status = [
        "security.allow_lazy_installs:",
        "HERMES_DISABLE_LAZY_INSTALLS:",
        "effective_lazy_installs:",
        "reason:",
    ]
    for needle in required_lazy:
        assert needle in lazy_text, f"lazy_deps missing {needle!r}"
    for needle in required_status:
        assert needle in status_text, f"status missing {needle!r}"
        assert needle in doctor_text, f"doctor missing {needle!r}"


def main() -> None:
    changed = False
    changed = patch_lazy_deps() or changed
    changed = patch_status() or changed
    changed = patch_doctor() or changed
    if not changed:
        print("lazy-install-policy-status: already patched")
    compile_targets()
    smoke_policy_helper()
    smoke_text_contract()
    print("lazy_install_policy_status_smoke_ok")


if __name__ == "__main__":
    main()
