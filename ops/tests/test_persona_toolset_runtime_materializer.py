#!/usr/bin/env python3
import importlib.util
import pathlib
import tempfile

root = pathlib.Path(__file__).resolve().parents[2]
script = root / "ops/scripts/materialize-persona-toolset-runtime.py"
spec = importlib.util.spec_from_file_location("persona_toolset_materializer", script)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

sample = '''CONFIGURABLE_TOOLSETS = [
    ("cronjob",         "⏰ Cron Jobs",                 "create/list/update/pause/resume/run, with optional attached skills"),
]
_DEFAULT_OFF_TOOLSETS = {"homeassistant", "spotify", "discord", "discord_admin", "video", "video_gen", "x_search"}
'''
with tempfile.TemporaryDirectory() as tmp:
    target = pathlib.Path(tmp) / "hermes_cli"
    target.mkdir()
    config = target / "tools_config.py"
    config.write_text(sample)
    module.patch(pathlib.Path(tmp))
    once = config.read_text()
    module.patch(pathlib.Path(tmp))
    twice = config.read_text()
    assert once == twice
    assert once.count('("persona",') == 1
    assert '"x_search", "persona"' in once

print("persona-toolset-runtime-materializer: PASS")


def assert_rejected_unchanged(content: str, expected_message: str) -> None:
    with tempfile.TemporaryDirectory() as tmp:
        target = pathlib.Path(tmp) / "hermes_cli"
        target.mkdir()
        config = target / "tools_config.py"
        config.write_text(content)
        before = config.read_bytes()
        try:
            module.patch(pathlib.Path(tmp))
        except SystemExit as exc:
            assert str(exc) == expected_message
        else:
            raise AssertionError("materializer accepted an unrecognized source shape")
        assert config.read_bytes() == before


assert_rejected_unchanged(
    sample.replace(
        '("cronjob",         "⏰ Cron Jobs",                 "create/list/update/pause/resume/run, with optional attached skills"),',
        '("cronjob", "changed anchor", "changed"),',
    ),
    "persona toolset patch anchor missing",
)
assert_rejected_unchanged(
    sample.replace(
        '_DEFAULT_OFF_TOOLSETS = {"homeassistant", "spotify", "discord", "discord_admin", "video", "video_gen", "x_search"}',
        '_DEFAULT_OFF_TOOLSETS = {"changed"}',
    ),
    "default-off patch anchor missing",
)

print("persona-toolset-runtime-fail-closed: PASS")