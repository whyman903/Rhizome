from __future__ import annotations

import os
from pathlib import Path

import pytest

from compile.config import Config, load_config, save_config, _load_dotenv


class TestConfig:
    def test_default_paths(self, tmp_path: Path) -> None:
        config = Config(topic="Test", workspace_root=tmp_path)
        assert config.raw_dir == tmp_path / "raw"
        assert config.wiki_dir == tmp_path / "wiki"
        assert config.compile_dir == tmp_path / ".compile"
        assert config.config_path == tmp_path / ".compile" / "config.yaml"
        assert config.state_path == tmp_path / ".compile" / "state.json"
        assert config.quarantine_dir == tmp_path / ".compile" / "quarantine"
        assert config.wiki_schema_path == tmp_path / "WIKI.md"

    def test_config_is_frozen(self, tmp_path: Path) -> None:
        config = Config(topic="Test", workspace_root=tmp_path)
        with pytest.raises(AttributeError):
            config.topic = "Changed"


class TestSaveAndLoadConfig:
    def test_round_trip(self, tmp_path: Path) -> None:
        config = Config(topic="Rhizome", description="A test wiki", workspace_root=tmp_path)
        save_config(config)

        loaded = load_config(tmp_path)
        assert loaded.topic == "Rhizome"
        assert loaded.description == "A test wiki"
        assert loaded.workspace_root == tmp_path

    def test_load_missing_workspace(self, tmp_path: Path) -> None:
        with pytest.raises(FileNotFoundError, match="No workspace found"):
            load_config(tmp_path)

    def test_load_empty_config_yaml(self, tmp_path: Path) -> None:
        compile_dir = tmp_path / ".compile"
        compile_dir.mkdir()
        (compile_dir / "config.yaml").write_text("")

        config = load_config(tmp_path)
        assert config.topic == "Untitled"
        assert config.description == ""

    def test_save_creates_compile_dir(self, tmp_path: Path) -> None:
        config = Config(topic="Test", workspace_root=tmp_path)
        assert not config.compile_dir.exists()
        save_config(config)
        assert config.config_path.exists()


class TestLoadDotenv:
    def test_loads_env_variables(self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
        env_file = tmp_path / ".env"
        env_file.write_text("TEST_COMPILE_VAR=hello\n")
        monkeypatch.delenv("TEST_COMPILE_VAR", raising=False)

        _load_dotenv(env_file)

        assert os.environ.get("TEST_COMPILE_VAR") == "hello"
        # Cleanup
        monkeypatch.delenv("TEST_COMPILE_VAR", raising=False)

    def test_does_not_override_existing(self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
        env_file = tmp_path / ".env"
        env_file.write_text("TEST_COMPILE_VAR=from_file\n")
        monkeypatch.setenv("TEST_COMPILE_VAR", "already_set")

        _load_dotenv(env_file)

        assert os.environ["TEST_COMPILE_VAR"] == "already_set"

    def test_skips_comments_and_blank_lines(self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
        env_file = tmp_path / ".env"
        env_file.write_text("# comment\n\nVALID_KEY=value\n")
        monkeypatch.delenv("VALID_KEY", raising=False)

        _load_dotenv(env_file)

        assert os.environ.get("VALID_KEY") == "value"
        monkeypatch.delenv("VALID_KEY", raising=False)

    def test_missing_file(self, tmp_path: Path) -> None:
        # Should not raise
        _load_dotenv(tmp_path / "nonexistent.env")
