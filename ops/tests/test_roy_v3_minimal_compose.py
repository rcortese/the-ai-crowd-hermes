from __future__ import annotations

from pathlib import Path
import re
import unittest

ROOT = Path(__file__).parents[2]
COMPOSE = ROOT / "compose.yaml"
FORBIDDEN = (
    "fiscal",
    "google",
    "oauth",
    "gog",
    "sheets",
    "drive_folder",
)


def service_block(name: str) -> str:
    text = COMPOSE.read_text()
    match = re.search(rf"(?ms)^  {re.escape(name)}:\n(?P<body>.*?)(?=^  [a-z0-9][a-z0-9-]*:\n|^networks:\n)", text)
    if not match:
        raise AssertionError(f"service-not-found:{name}")
    return match.group(0)


class MinimalReleaseComposeTests(unittest.TestCase):
    def test_roy_binds_only_the_approved_single_user_telegram_channel(self):
        block = service_block("roy").lower()
        for term in FORBIDDEN:
            self.assertNotIn(term, block)
        self.assertIn("telegram_bot_token: ${roy_telegram_bot_token:?", block)
        self.assertIn("telegram_allowed_users: ${roy_telegram_home_channel:?", block)
        self.assertIn("telegram_home_channel: ${roy_telegram_home_channel:?", block)
        self.assertIn("telegram_home_channel_thread_id: ${roy_telegram_home_channel_thread_id:-}", block)
        self.assertNotIn("telegram_allow_all_users", block)
        self.assertNotIn("telegram_allowed_chats", block)
        self.assertIn("- ./env/roy-v3.env", block)
        self.assertNotIn("*hermes-fleet-env-file", block)
        self.assertNotIn("./env/roy.env", block)

    def test_roy_mounts_only_v3_and_selected_shared_roots(self):
        block = service_block("roy")
        self.assertIn("./agents/private/roy-v3:/opt/personal-assistant:ro", block)
        self.assertIn("./runtime/roy-v3-home:/opt/data", block)
        self.assertIn("./state/private/roy-v3-workspace:/agents/roy/private:rw", block)
        self.assertIn("./state/shared/openai-codex-auth-fleet:/mnt/hermes-auth-shared:ro", block)
        self.assertNotIn("roy-home", block.replace("roy-v3-home", ""))
        self.assertNotIn("docker.sock", block)


if __name__ == "__main__":
    unittest.main()
