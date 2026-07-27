from __future__ import annotations

from pathlib import Path

from hf_rag.config import load_config


def _write_credentials(
    path: Path, qdrant_key: str = "test-key", gb10_key: str = "test-key"
) -> None:
    path.write_text(
        f'[keys]\nqdrant_api_key = "{qdrant_key}"\ngb10_api_key = "{gb10_key}"\n',
        encoding="utf-8",
    )
    path.chmod(0o600)


def _write_config_and_credentials(tmp_path: Path) -> Path:
    config_path = tmp_path / "ragctl.toml"
    config_path.write_text("[rag]\n", encoding="utf-8")
    _write_credentials(tmp_path / "credentials.toml")
    return config_path


def test_credentials_file_supplies_keys_when_environment_is_missing(
    monkeypatch, tmp_path: Path
) -> None:
    monkeypatch.delenv("QDRANT_API_KEY", raising=False)
    monkeypatch.delenv("GB10_API_KEY", raising=False)
    monkeypatch.delenv("RAGCTL_CREDENTIALS", raising=False)
    monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path / "xdg"))
    monkeypatch.setenv("HOME", str(tmp_path / "home"))

    config = load_config(_write_config_and_credentials(tmp_path))

    assert config.qdrant_api_key() == "test-key"
    assert config.api_key() == "test-key"
    assert "test-key" not in repr(config)


def test_environment_keys_override_credentials_file(monkeypatch, tmp_path: Path) -> None:
    monkeypatch.setenv("QDRANT_API_KEY", "override-test-key")
    monkeypatch.setenv("GB10_API_KEY", "override-test-key")
    monkeypatch.delenv("RAGCTL_CREDENTIALS", raising=False)
    monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path / "xdg"))
    monkeypatch.setenv("HOME", str(tmp_path / "home"))

    config = load_config(_write_config_and_credentials(tmp_path))

    assert config.qdrant_api_key() == "override-test-key"
    assert config.api_key() == "override-test-key"


def test_ragctl_credentials_path_precedes_config_adjacent_file(monkeypatch, tmp_path: Path) -> None:
    monkeypatch.delenv("QDRANT_API_KEY", raising=False)
    monkeypatch.delenv("GB10_API_KEY", raising=False)
    monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path / "xdg"))
    monkeypatch.setenv("HOME", str(tmp_path / "home"))
    preferred_path = tmp_path / "preferred-credentials.toml"
    _write_credentials(preferred_path, "preferred-test-key", "preferred-test-key")
    monkeypatch.setenv("RAGCTL_CREDENTIALS", str(preferred_path))

    config = load_config(_write_config_and_credentials(tmp_path))

    assert config.qdrant_api_key() == "preferred-test-key"
    assert config.api_key() == "preferred-test-key"
