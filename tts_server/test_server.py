# server.py 단위 테스트 — 로그·STT·메트릭·DLQ·인터럽트 검증
import os
import time
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from tts_server.server import _log, app
from tts_server.supervisor import _do_cleanup


@pytest.fixture
def client():
    with TestClient(app) as c:
        yield c



class TestStructuredLog:
    def test_info_prefix(self, capsys):
        _log("INFO", "서버 시작")
        assert "[INFO]" in capsys.readouterr().out

    def test_error_prefix(self, capsys):
        _log("ERROR", "오류 발생")
        assert "[ERROR]" in capsys.readouterr().out

    def test_timestamp_included(self, capsys):
        import re
        _log("INFO", "타임스탬프 확인")
        assert re.search(r"\d{4}-\d{2}-\d{2}", capsys.readouterr().out)


class TestSpoolCleanup:
    def test_old_files_removed(self, tmp_path):
        old = tmp_path / "old.wav"
        old.write_bytes(b"x")
        old_time = time.time() - 400
        os.utime(old, (old_time, old_time))
        _do_cleanup(tmp_path)
        assert not old.exists()

    def test_max_10_files_enforced(self, tmp_path):
        for i in range(12):
            f = tmp_path / f"{i:010d}_100.wav"
            f.write_bytes(b"x")
            t = time.time() - (12 - i)
            os.utime(f, (t, t))
        _do_cleanup(tmp_path)
        assert len(list(tmp_path.glob("*.wav"))) == 10


def test_stt_status_disabled():
    from unittest.mock import patch, MagicMock
    from fastapi.testclient import TestClient
    from tts_server.server import app
    from hook_voice.config import SttConfig
    mock_cfg = MagicMock()
    mock_cfg.stt = SttConfig(enabled=False)
    with patch("tts_server.server._load_voice_config", return_value=mock_cfg):
        with TestClient(app) as client:
            r = client.get("/stt/status")
    assert r.status_code == 200
    assert r.json()["state"] == "disabled"


def test_stt_toggle_disabled_returns_503():
    from unittest.mock import patch, MagicMock
    from fastapi.testclient import TestClient
    from tts_server.server import app
    from hook_voice.config import SttConfig
    mock_cfg = MagicMock()
    mock_cfg.stt = SttConfig(enabled=False)
    with patch("tts_server.server._load_voice_config", return_value=mock_cfg):
        with TestClient(app) as client:
            r = client.post("/stt/toggle")
    assert r.status_code == 503


def test_metrics_json_includes_cb_and_dlq():
    from fastapi.testclient import TestClient
    from tts_server.server import app
    with TestClient(app) as client:
        r = client.get("/metrics/json")
    assert r.status_code == 200
    data = r.json()
    assert "circuit_breakers" in data
    assert "dlq_pending" in data


def test_interrupt_no_active_player():
    """재생 중이 아닐 때 interrupt 요청 → {"status": "not_playing"}"""
    spool = Path("/tmp/tts-spool")
    spool.mkdir(exist_ok=True)
    pid_file = spool / ".player.pid"
    pid_file.unlink(missing_ok=True)

    with TestClient(app) as client:
        r = client.post("/interrupt")
    assert r.status_code == 200
    data = r.json()
    assert data["status"] in ("not_playing", "interrupted")


def test_interrupt_returns_json():
    """interrupt 엔드포인트가 JSON을 반환한다"""
    with TestClient(app) as client:
        r = client.post("/interrupt")
    assert r.status_code == 200
    assert "status" in r.json()


def test_playback_status():
    """playback/status 엔드포인트가 is_playing과 queue_depth를 포함한다"""
    with TestClient(app) as client:
        r = client.get("/playback/status")
    assert r.status_code == 200
    data = r.json()
    assert "is_playing" in data
    assert "queue_depth" in data


def test_health_includes_queue_depth(client):
    """GET /health가 queue_depth를 포함한다."""
    r = client.get("/health")
    assert r.status_code == 200
    data = r.json()
    assert "queue_depth" in data
    assert isinstance(data["queue_depth"], int)


def test_health_includes_model_loaded(client):
    """GET /health가 model_loaded 필드를 포함한다."""
    r = client.get("/health")
    assert r.status_code == 200
    data = r.json()
    assert "model_loaded" in data
    assert isinstance(data["model_loaded"], bool)


def test_health_includes_stt_enabled(client):
    """GET /health가 stt_enabled 필드를 포함한다."""
    r = client.get("/health")
    assert r.status_code == 200
    data = r.json()
    assert "stt_enabled" in data
    assert isinstance(data["stt_enabled"], bool)


def test_interrupt_no_body_returns_resume_threshold():
    """interrupt 요청 body 없이도 resume_threshold 필드가 반환된다."""
    spool = Path("/tmp/tts-spool")
    spool.mkdir(exist_ok=True)
    pid_file = spool / ".player.pid"
    pid_file.unlink(missing_ok=True)

    with TestClient(app) as client:
        r = client.post("/interrupt")
    assert r.status_code == 200
    data = r.json()
    assert "resume_threshold" in data
    assert isinstance(data["resume_threshold"], float)


def test_interrupt_with_force_false():
    """interrupt force=False 요청 — resume_threshold 포함된 응답 반환."""
    spool = Path("/tmp/tts-spool")
    spool.mkdir(exist_ok=True)
    pid_file = spool / ".player.pid"
    pid_file.unlink(missing_ok=True)

    with TestClient(app) as client:
        r = client.post("/interrupt", json={"force": False})
    assert r.status_code == 200
    data = r.json()
    assert "status" in data
    assert "resume_threshold" in data
    assert data["resume_threshold"] == 0.0  # 기본값


def test_interrupt_with_force_true():
    """interrupt force=True 요청 — 즉시 종료, resume_threshold는 0.0 기본값."""
    spool = Path("/tmp/tts-spool")
    spool.mkdir(exist_ok=True)
    pid_file = spool / ".player.pid"
    pid_file.unlink(missing_ok=True)

    with TestClient(app) as client:
        r = client.post("/interrupt", json={"force": True})
    assert r.status_code == 200
    data = r.json()
    assert data["status"] in ("not_playing", "interrupted")
    assert "resume_threshold" in data
