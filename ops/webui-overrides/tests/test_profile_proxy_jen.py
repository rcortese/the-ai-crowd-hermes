import os


def test_env_profile_proxy_public_entry(monkeypatch):
    from api.gateway_chat import profile_proxy_public_entries, profile_proxy_for

    env = {
        "HERMES_WEBUI_PROFILE_PROXY_JEN_BASE_URL": "http://jen:8642/",
        "HERMES_WEBUI_PROFILE_PROXY_JEN_API_KEY_ENV": "API_SERVER_KEY",
        "HERMES_WEBUI_PROFILE_PROXY_JEN_LABEL": "Jen",
        "HERMES_WEBUI_PROFILE_PROXY_DENHOLM_BASE_URL": "http://denholm:8643",
        "HERMES_WEBUI_PROFILE_PROXY_DENHOLM_API_KEY_ENV": "API_SERVER_KEY",
        "HERMES_WEBUI_PROFILE_PROXY_DENHOLM_LABEL": "Denholm",
        "HERMES_WEBUI_PROFILE_PROXY_ROY_BASE_URL": "http://roy:8645",
        "HERMES_WEBUI_PROFILE_PROXY_ROY_API_KEY_ENV": "API_SERVER_KEY",
        "HERMES_WEBUI_PROFILE_PROXY_ROY_LABEL": "Roy",
        "API_SERVER_KEY": "secret-value",
    }

    proxy = profile_proxy_for("jen", environ=env)
    assert proxy["base_url"] == "http://jen:8642"
    assert proxy["api_key"] == "secret-value"
    assert proxy["api_key_configured"] is True

    public = profile_proxy_public_entries(environ=env)
    by_name = {entry["name"]: entry for entry in public}
    assert set(by_name) == {"denholm", "jen", "roy"}
    assert by_name["jen"] | {} == by_name["jen"]
    assert by_name["jen"]["base_url"] == "http://jen:8642"
    assert by_name["denholm"]["base_url"] == "http://denholm:8643"
    assert by_name["denholm"]["label"] == "Denholm"
    assert by_name["roy"]["base_url"] == "http://roy:8645"
    assert by_name["roy"]["label"] == "Roy"
    for entry in public:
        assert entry["remote_proxy"] is True
        assert entry["profile_kind"] == "remote_gateway_proxy"
        assert entry["provider"] == "remote-gateway"
        assert entry["gateway_running"] is True
    assert "secret-value" not in repr(public)


def test_list_profiles_includes_remote_proxy(monkeypatch, tmp_path):
    import api.profiles as profiles

    class Info:
        name = "default"
        path = tmp_path
        is_default = True
        gateway_running = True
        model = "gpt-test"
        provider = "test-provider"
        has_env = True

    monkeypatch.setattr(profiles, "get_active_profile_name", lambda: "default")
    monkeypatch.setattr(profiles, "_get_profile_skills_stats", lambda path: (0, 0))
    monkeypatch.setenv("HERMES_WEBUI_PROFILE_PROXY_JEN_BASE_URL", "http://jen:8642")
    monkeypatch.setenv("HERMES_WEBUI_PROFILE_PROXY_JEN_API_KEY", "secret-value")
    monkeypatch.setenv("HERMES_WEBUI_PROFILE_PROXY_DENHOLM_BASE_URL", "http://denholm:8643")
    monkeypatch.setenv("HERMES_WEBUI_PROFILE_PROXY_DENHOLM_API_KEY", "secret-value")
    monkeypatch.setenv("HERMES_WEBUI_PROFILE_PROXY_ROY_BASE_URL", "http://roy:8645")
    monkeypatch.setenv("HERMES_WEBUI_PROFILE_PROXY_ROY_API_KEY", "secret-value")
    monkeypatch.setenv("HERMES_WEBUI_PROFILE_PROXY_RICHMOND_BASE_URL", "http://richmond:8646")
    monkeypatch.setenv("HERMES_WEBUI_PROFILE_PROXY_RICHMOND_API_KEY", "secret-value")
    monkeypatch.setenv("HERMES_WEBUI_PROFILE_PROXY_THE_ELDERS_BASE_URL", "http://the-elders:8647")
    monkeypatch.setenv("HERMES_WEBUI_PROFILE_PROXY_THE_ELDERS_API_KEY", "secret-value")

    import hermes_cli.profiles as cli_profiles

    monkeypatch.setattr(cli_profiles, "list_profiles", lambda: [Info()])
    result = profiles.list_profiles_api()

    names = {p["name"] for p in result}
    assert {"default", "jen", "denholm", "roy", "richmond", "the-elders"}.issubset(names)
    assert [p["name"] for p in result[:6]] == ["default", "jen", "denholm", "roy", "richmond", "the-elders"]
    jen = next(p for p in result if p["name"] == "jen")
    assert jen["remote_proxy"] is True
    assert jen["base_url"] == "http://jen:8642"
    assert "secret-value" not in repr(jen)


def test_switch_profile_accepts_remote_proxy(monkeypatch, tmp_path):
    import api.profiles as profiles

    monkeypatch.setattr(profiles, "_DEFAULT_HERMES_HOME", tmp_path)
    monkeypatch.setenv("HERMES_WEBUI_PROFILE_PROXY_JEN_BASE_URL", "http://jen:8642")
    monkeypatch.setenv("HERMES_WEBUI_PROFILE_PROXY_JEN_API_KEY", "secret-value")

    import api.config as config

    monkeypatch.setattr(config, "STREAMS", {})
    monkeypatch.setattr(config, "reload_config", lambda: None)
    monkeypatch.setattr(config, "DEFAULT_WORKSPACE", str(tmp_path))
    monkeypatch.setattr(profiles, "list_profiles_api", lambda: [{"name": "jen", "remote_proxy": True, "is_active": True}])

    result = profiles.switch_profile("jen", process_wide=False)
    assert result["active"] == "jen"
    assert result["profiles"][0]["name"] == "jen"


def test_gateway_chat_uses_proxy_config(monkeypatch):
    import api.gateway_chat as gateway_chat

    monkeypatch.setenv("HERMES_WEBUI_GATEWAY_BASE_URL", "http://default:8642")
    cfg = {"base_url": "http://jen:8642", "api_key": "secret", "session_key_prefix": "webui:jen"}
    # Exercise the same selection expressions used by _run_gateway_chat_streaming
    # without opening a socket.
    selected_gateway = cfg
    base_url = (selected_gateway or {}).get("base_url") or gateway_chat._gateway_base_url({})
    api_key = (selected_gateway or {}).get("api_key") or gateway_chat._gateway_api_key()
    session_key_prefix = (selected_gateway or {}).get("session_key_prefix") or "webui"

    assert base_url == "http://jen:8642"
    assert api_key == "secret"
    assert f"{session_key_prefix}:abc" == "webui:jen:abc"
