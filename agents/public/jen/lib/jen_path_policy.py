"""State-path policy shared by Jen Python runtime helpers."""
from pathlib import Path

SHARED_STORAGE_ROOT = Path("/mnt/hermes-shared")


def require_local_state_path(value: str | Path) -> Path:
    resolved = Path(value).expanduser().resolve(strict=False)
    if resolved == SHARED_STORAGE_ROOT or SHARED_STORAGE_ROOT in resolved.parents:
        raise ValueError("shared_state_path_forbidden")
    return resolved
