#!/usr/bin/env python3
"""Patch Hermes web search to support configured search fallback backends."""

from __future__ import annotations

import json
import py_compile
from pathlib import Path

TARGET = Path("/opt/hermes/tools/web_tools.py")

HELPER_ANCHOR = """def _get_extract_backend() -> str:
    \"\"\"Determine which backend to use for web_extract specifically.

    Selection priority:
    1. ``web.extract_backend`` (per-capability override)
    2. ``web.backend`` (shared fallback — existing behavior)
    3. Auto-detect from env vars
    \"\"\"
    return _get_capability_backend("extract")


"""

HELPER_BLOCK = """def _normalise_backend_name_list(raw: object) -> list[str]:
    # Return a normalized list of backend names from YAML/list/env values.
    if raw is None:
        return []
    if isinstance(raw, str):
        parts = raw.replace(";", ",").split(",")
    elif isinstance(raw, (list, tuple, set)):
        parts = [str(item) for item in raw]
    else:
        parts = [str(raw)]

    valid = {"parallel", "firecrawl", "tavily", "exa", "searxng", "brave-free", "ddgs", "xai"}
    names: list[str] = []
    seen: set[str] = set()
    for part in parts:
        name = part.strip().lower()
        if not name or name not in valid or name in seen:
            continue
        names.append(name)
        seen.add(name)
    return names


def _get_search_fallback_backends(primary_backend: str = "") -> list[str]:
    # Return configured fallback backends for web_search only.
    # web.search_backend remains primary. web.search_fallback_backends is an
    # ordered list, or comma-separated string, tried only when primary raises
    # or returns success=false. web.search_fallback_backend is a single alias.
    # HERMES_WEB_SEARCH_FALLBACK_BACKENDS is a process-env override.
    cfg = _load_web_config()
    raw = cfg.get("search_fallback_backends")
    if raw is None:
        raw = cfg.get("search_fallback_backend")
    if raw is None:
        raw = os.getenv("HERMES_WEB_SEARCH_FALLBACK_BACKENDS", "")

    primary = (primary_backend or "").strip().lower()
    return [name for name in _normalise_backend_name_list(raw) if name != primary]


"""

OLD_SEARCH_BLOCK = """        backend = _get_search_backend()
        provider = _wsp_get_provider(backend) if backend else None
        if provider is None or not provider.supports_search():
            # Fall back to availability-walked active provider when the
            # configured backend isn't a registered search provider (typo,
            # uninstalled plugin, or capability mismatch).
            provider = get_active_search_provider()

        if provider is None:
            response_data = {
                "success": False,
                "error": (
                    "No web search provider configured. "
                    "Run `hermes tools` to set one up."
                ),
            }
        else:
            logger.info(
                "Web search via %s: '%s' (limit: %d)",
                provider.name, query, limit,
            )
            response_data = provider.search(query, limit)
"""

NEW_SEARCH_BLOCK = """        backend = _get_search_backend()
        provider = _wsp_get_provider(backend) if backend else None
        if provider is None or not provider.supports_search():
            # Fall back to availability-walked active provider when the
            # configured backend isn't a registered search provider (typo,
            # uninstalled plugin, or capability mismatch).
            provider = get_active_search_provider()

        providers = []
        seen_provider_names = set()

        def _append_search_provider(candidate: object) -> None:
            if candidate is None:
                return
            name = getattr(candidate, "name", "")
            supports = getattr(candidate, "supports_search", None)
            if not name or name in seen_provider_names or not callable(supports) or not supports():
                return
            providers.append(candidate)
            seen_provider_names.add(name)

        _append_search_provider(provider)
        primary_name = getattr(provider, "name", backend or "")
        for fallback_backend in _get_search_fallback_backends(primary_name):
            if not _is_backend_available(fallback_backend):
                logger.info(
                    "Skipping unavailable web search fallback provider %s",
                    fallback_backend,
                )
                continue
            _append_search_provider(_wsp_get_provider(fallback_backend))

        if not providers:
            response_data = {
                "success": False,
                "error": (
                    "No web search provider configured. "
                    "Run `hermes tools` to set one up."
                ),
            }
        else:
            failures = []
            response_data = None
            for index, candidate in enumerate(providers):
                role = "primary" if index == 0 else "fallback"
                try:
                    logger.info(
                        "Web search via %s provider %s: '%s' (limit: %d)",
                        role, candidate.name, query, limit,
                    )
                    candidate_response = candidate.search(query, limit)
                except Exception as exc:  # noqa: BLE001 - fallback path needs provider errors
                    failures.append(f"{candidate.name}: {exc}")
                    logger.warning(
                        "Web search provider %s failed; trying fallback if configured: %s",
                        candidate.name, exc,
                    )
                    continue

                if not isinstance(candidate_response, dict):
                    failures.append(f"{candidate.name}: returned non-dict response")
                    logger.warning(
                        "Web search provider %s returned a non-dict response; trying fallback if configured",
                        candidate.name,
                    )
                    continue

                if candidate_response.get("success") is False:
                    err = str(candidate_response.get("error") or "success=false")
                    failures.append(f"{candidate.name}: {err}")
                    logger.warning(
                        "Web search provider %s returned success=false; trying fallback if configured: %s",
                        candidate.name, err,
                    )
                    continue

                response_data = candidate_response
                if index > 0:
                    metadata = response_data.setdefault("metadata", {})
                    metadata.setdefault("backend", candidate.name)
                    metadata.setdefault("fallback_from", providers[0].name)
                    metadata.setdefault("fallback_failures", failures)
                break

            if response_data is None:
                response_data = {
                    "success": False,
                    "error": "All configured web search providers failed: " + "; ".join(failures),
                }
"""


def patch_file() -> None:
    text = TARGET.read_text()
    changed = False

    if "def _get_search_fallback_backends" not in text:
        if HELPER_ANCHOR not in text:
            raise SystemExit("web-search-fallback: helper insertion anchor not found")
        text = text.replace(HELPER_ANCHOR, HELPER_ANCHOR + HELPER_BLOCK, 1)
        changed = True

    if NEW_SEARCH_BLOCK not in text:
        if OLD_SEARCH_BLOCK not in text:
            raise SystemExit("web-search-fallback: expected web_search_tool dispatch block not found")
        text = text.replace(OLD_SEARCH_BLOCK, NEW_SEARCH_BLOCK, 1)
        changed = True

    if changed:
        TARGET.write_text(text)
        print("web-search-fallback: patched /opt/hermes/tools/web_tools.py")
    else:
        print("web-search-fallback: already patched")

    py_compile.compile(str(TARGET), doraise=True)


def smoke_test() -> None:
    import agent.web_search_registry as registry
    import tools.web_tools as web_tools

    class FailingProvider:
        name = "firecrawl"
        def supports_search(self) -> bool:
            return True
        def search(self, query: str, limit: int = 5) -> dict:
            return {"success": False, "error": "synthetic primary failure"}

    class FallbackProvider:
        name = "brave-free"
        def supports_search(self) -> bool:
            return True
        def search(self, query: str, limit: int = 5) -> dict:
            return {
                "success": True,
                "data": {"web": [{"title": "fallback-ok", "url": "https://example.test", "description": "", "position": 1}]},
            }

    providers = {"firecrawl": FailingProvider(), "brave-free": FallbackProvider()}
    original_loader = web_tools._ensure_web_plugins_loaded
    original_cfg = web_tools._load_web_config
    original_available = web_tools._is_backend_available
    original_get_provider = registry.get_provider
    original_get_active = registry.get_active_search_provider
    try:
        web_tools._ensure_web_plugins_loaded = lambda: None
        web_tools._load_web_config = lambda: {
            "search_backend": "firecrawl",
            "search_fallback_backends": ["brave-free"],
        }
        web_tools._is_backend_available = lambda backend: backend in providers
        registry.get_provider = lambda name: providers.get(name)
        registry.get_active_search_provider = lambda: providers["firecrawl"]
        result = json.loads(web_tools.web_search_tool("synthetic query", 1))
        assert result["success"] is True, result
        assert result["data"]["web"][0]["title"] == "fallback-ok", result
        metadata = result.get("metadata", {})
        assert metadata.get("backend") == "brave-free", result
        assert metadata.get("fallback_from") == "firecrawl", result
    finally:
        web_tools._ensure_web_plugins_loaded = original_loader
        web_tools._load_web_config = original_cfg
        web_tools._is_backend_available = original_available
        registry.get_provider = original_get_provider
        registry.get_active_search_provider = original_get_active
    print("web_search_fallback_smoke_ok")


def main() -> None:
    patch_file()
    smoke_test()


if __name__ == "__main__":
    main()
