# tests/hud/test_snapshot.py — HUD 스냅샷 저장·로드·레이블 생성 단위 테스트
import json
import pytest
from pathlib import Path

from hook_voice.hud.snapshot import load_snapshot, save_snapshot, build_label


# ---------------------------------------------------------------------------
# load_snapshot
# ---------------------------------------------------------------------------

def test_load_snapshot_returns_safe_defaults_when_file_missing(tmp_path):
    result = load_snapshot(tmp_path / "nonexistent.json")
    assert isinstance(result, dict)
    assert "mode" in result
    assert "voice" in result
    assert "auto_speak" in result


def test_load_snapshot_returns_safe_defaults_on_malformed_json(tmp_path):
    bad = tmp_path / "hud.json"
    bad.write_text("{{not json", encoding="utf-8")
    result = load_snapshot(bad)
    assert isinstance(result, dict)
    # 절대 raise 금지 — 기본값 반환
    assert "mode" in result


def test_load_snapshot_never_raises_on_permission_error(tmp_path, monkeypatch):
    p = tmp_path / "hud.json"
    p.write_text("{}", encoding="utf-8")
    monkeypatch.setattr(Path, "read_text", lambda *a, **kw: (_ for _ in ()).throw(PermissionError("no")))
    # 절대 raise 금지
    result = load_snapshot(p)
    assert isinstance(result, dict)


def test_load_snapshot_returns_saved_data(tmp_path):
    p = tmp_path / "hud.json"
    data = {"mode": "focus", "voice": "M3", "auto_speak": False, "extra": 42}
    save_snapshot(data, p)
    result = load_snapshot(p)
    assert result["mode"] == "focus"
    assert result["voice"] == "M3"
    assert result["auto_speak"] is False
    assert result["extra"] == 42


def test_load_snapshot_uses_default_path_when_none(monkeypatch, tmp_path):
    """path=None 이면 내부 기본 경로를 사용한다 — 파일 없으면 기본값 반환."""
    import hook_voice.hud.snapshot as snap_mod
    monkeypatch.setattr(snap_mod, "_DEFAULT_SNAPSHOT_PATH", tmp_path / "hud.json")
    result = load_snapshot()
    assert isinstance(result, dict)


# ---------------------------------------------------------------------------
# save_snapshot — atomic write
# ---------------------------------------------------------------------------

def test_save_snapshot_creates_file(tmp_path):
    p = tmp_path / "hud.json"
    save_snapshot({"mode": "normal"}, p)
    assert p.exists()


def test_save_snapshot_creates_parent_directories(tmp_path):
    p = tmp_path / "deep" / "nested" / "hud.json"
    save_snapshot({"mode": "quiet"}, p)
    assert p.exists()


def test_save_snapshot_writes_valid_json(tmp_path):
    p = tmp_path / "hud.json"
    save_snapshot({"mode": "verbose", "auto_speak": True}, p)
    loaded = json.loads(p.read_text(encoding="utf-8"))
    assert loaded["mode"] == "verbose"
    assert loaded["auto_speak"] is True


def test_save_snapshot_is_atomic_no_partial_file(tmp_path, monkeypatch):
    """임시 파일이 정리된 뒤 원본 경로에만 파일이 남아야 한다."""
    p = tmp_path / "hud.json"
    save_snapshot({"mode": "normal"}, p)
    # tmp 파일(.tmp)이 남아있지 않아야 함
    tmp_files = list(tmp_path.glob("*.tmp"))
    assert tmp_files == []


def test_save_snapshot_redacts_token_like_values(tmp_path):
    """30자 이상의 영숫자+특수문자 값은 [REDACTED]로 치환된다."""
    p = tmp_path / "hud.json"
    secret = "sk-abcdefghij1234567890ABCDEFGHIJ"  # 32자
    save_snapshot({"api_key": secret, "mode": "normal"}, p)
    loaded = json.loads(p.read_text(encoding="utf-8"))
    assert loaded["api_key"] == "[REDACTED]"
    assert loaded["mode"] == "normal"  # 짧은 값은 보존


def test_save_snapshot_keeps_short_values(tmp_path):
    """29자 이하 값은 redact하지 않는다."""
    p = tmp_path / "hud.json"
    short = "a" * 29
    save_snapshot({"key": short}, p)
    loaded = json.loads(p.read_text(encoding="utf-8"))
    assert loaded["key"] == short


def test_save_snapshot_redact_boundary_exactly_30(tmp_path):
    """정확히 30자이면 redact된다."""
    p = tmp_path / "hud.json"
    val30 = "A" * 30
    save_snapshot({"token": val30}, p)
    loaded = json.loads(p.read_text(encoding="utf-8"))
    assert loaded["token"] == "[REDACTED]"


def test_save_snapshot_redact_only_string_values(tmp_path):
    """비문자열 값(숫자, bool)은 redact하지 않는다."""
    p = tmp_path / "hud.json"
    save_snapshot({"count": 12345678901234567890, "flag": True}, p)
    loaded = json.loads(p.read_text(encoding="utf-8"))
    assert loaded["flag"] is True


def test_save_snapshot_does_not_raise_on_write_failure(tmp_path, monkeypatch):
    """쓰기 실패 시 raise하지 않는다 (best-effort)."""
    import hook_voice.hud.snapshot as snap_mod

    original_rename = Path.rename
    def bad_rename(self, target):
        raise OSError("disk full")

    monkeypatch.setattr(Path, "rename", bad_rename)
    # 예외 없이 조용히 실패해야 함
    save_snapshot({"mode": "normal"}, tmp_path / "hud.json")


# ---------------------------------------------------------------------------
# build_label
# ---------------------------------------------------------------------------

def test_build_label_returns_string(tmp_path):
    result = build_label({"mode": "normal", "voice": "F1", "auto_speak": True})
    assert isinstance(result, str)


def test_build_label_max_50_chars_default():
    snapshot = {"mode": "verbose", "voice": "M4", "auto_speak": True, "extra": "x" * 100}
    label = build_label(snapshot)
    assert len(label) <= 50


def test_build_label_respects_custom_max_chars():
    snapshot = {"mode": "normal", "voice": "F1", "auto_speak": True}
    label = build_label(snapshot, max_chars=20)
    assert len(label) <= 20


def test_build_label_includes_mode():
    snapshot = {"mode": "focus", "voice": "M1", "auto_speak": True}
    label = build_label(snapshot)
    assert "focus" in label


def test_build_label_on_empty_snapshot():
    label = build_label({})
    assert isinstance(label, str)
    assert len(label) <= 50


def test_build_label_on_missing_mode_key():
    label = build_label({"voice": "F2"})
    assert isinstance(label, str)
    assert len(label) <= 50


def test_build_label_always_within_limit_with_long_values():
    snapshot = {"mode": "x" * 100, "voice": "y" * 100, "auto_speak": False}
    for max_c in [10, 20, 50, 80]:
        label = build_label(snapshot, max_chars=max_c)
        assert len(label) <= max_c, f"max_chars={max_c}, len={len(label)}"


# ---------------------------------------------------------------------------
# HudConfig in config.py
# ---------------------------------------------------------------------------

def test_hudconfig_default_values():
    from hook_voice.config import HudConfig
    cfg = HudConfig()
    assert cfg.snapshot_path is None
    assert isinstance(cfg.max_label_chars, int)
    assert cfg.max_label_chars <= 50


def test_voiceconfig_has_hud_field():
    from hook_voice.config import Config
    cfg = Config()
    from hook_voice.config import HudConfig
    assert isinstance(cfg.hud, HudConfig)


def test_voiceconfig_hud_is_independent_instance():
    from hook_voice.config import Config
    cfg1 = Config()
    cfg2 = Config()
    assert cfg1.hud is not cfg2.hud
