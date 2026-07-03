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


# ── /chorus/hud 테스트 ────────────────────────────────────────────────────────

class TestChorusHud:
    """GET /chorus/hud 엔드포인트 테스트"""

    def test_normal_state_returns_200(self):
        """정상 상태 (모델 로드됨, 재생 중) — 200 반환 및 필수 필드 포함."""
        from unittest.mock import patch, MagicMock
        from tts_server.server import app
        from hook_voice.config import Config, SttConfig

        mock_cfg = MagicMock(spec=Config)
        mock_cfg.auto_speak = True
        mock_cfg.voice_mode = "normal"
        mock_cfg.hud = MagicMock()
        mock_cfg.hud.max_label_chars = 50
        mock_cfg.hud.snapshot_path = None
        mock_cfg.stt = SttConfig(enabled=True)

        with patch("tts_server.server._model", new=object()), \
             patch("tts_server.server._stt_listener", new=MagicMock(state="idle")), \
             patch("tts_server.server._load_voice_config", return_value=mock_cfg), \
             patch("tts_server.server._get_dlq_store") as mock_dlq:
            mock_dlq.return_value.stats.return_value = {"pending": 0}
            with TestClient(app) as client:
                r = client.get("/chorus/hud")

        assert r.status_code == 200
        data = r.json()
        assert "label" in data
        assert "severity" in data
        assert "auto_speak" in data
        assert "voice_mode" in data
        assert "queue_depth" in data
        assert "is_playing" in data
        assert "stt_state" in data
        assert "dlq_pending" in data
        assert "last_event" in data
        assert "suggestion" in data

    def test_not_playing_state(self):
        """재생 안 됨 (is_playing=False) — 200 반환."""
        from unittest.mock import patch, MagicMock
        from tts_server.server import app
        from hook_voice.config import Config, SttConfig

        # 테스트 격리: PID 파일 제거
        spool = Path("/tmp/tts-spool")
        spool.mkdir(exist_ok=True)
        (spool / ".player.pid").unlink(missing_ok=True)

        mock_cfg = MagicMock(spec=Config)
        mock_cfg.auto_speak = True
        mock_cfg.voice_mode = "focus"
        mock_cfg.hud = MagicMock()
        mock_cfg.hud.max_label_chars = 50
        mock_cfg.hud.snapshot_path = None
        mock_cfg.stt = SttConfig(enabled=False)

        with patch("tts_server.server._model", new=object()), \
             patch("tts_server.server._stt_listener", new=None), \
             patch("tts_server.server._load_voice_config", return_value=mock_cfg), \
             patch("tts_server.server._get_dlq_store") as mock_dlq:
            mock_dlq.return_value.stats.return_value = {"pending": 0}
            with TestClient(app) as client:
                r = client.get("/chorus/hud")

        assert r.status_code == 200
        data = r.json()
        assert data["stt_state"] == "disabled"
        assert data["is_playing"] is False

    def test_stt_disabled_state(self):
        """STT 비활성화 (stt_state='disabled') — 200 반환."""
        from unittest.mock import patch, MagicMock
        from tts_server.server import app
        from hook_voice.config import Config, SttConfig

        mock_cfg = MagicMock(spec=Config)
        mock_cfg.auto_speak = False
        mock_cfg.voice_mode = "quiet"
        mock_cfg.hud = MagicMock()
        mock_cfg.hud.max_label_chars = 50
        mock_cfg.hud.snapshot_path = None
        mock_cfg.stt = SttConfig(enabled=False)

        with patch("tts_server.server._model", new=object()), \
             patch("tts_server.server._stt_listener", new=None), \
             patch("tts_server.server._load_voice_config", return_value=mock_cfg), \
             patch("tts_server.server._get_dlq_store") as mock_dlq:
            mock_dlq.return_value.stats.return_value = {"pending": 0}
            with TestClient(app) as client:
                r = client.get("/chorus/hud")

        assert r.status_code == 200
        data = r.json()
        assert data["stt_state"] == "disabled"

    def test_dlq_pending_severity_warn(self):
        """DLQ pending > 0 이면 severity='warn'."""
        from unittest.mock import patch, MagicMock
        from tts_server.server import app
        from hook_voice.config import Config, SttConfig

        mock_cfg = MagicMock(spec=Config)
        mock_cfg.auto_speak = True
        mock_cfg.voice_mode = "normal"
        mock_cfg.hud = MagicMock()
        mock_cfg.hud.max_label_chars = 50
        mock_cfg.hud.snapshot_path = None
        mock_cfg.stt = SttConfig(enabled=False)

        with patch("tts_server.server._model", new=object()), \
             patch("tts_server.server._stt_listener", new=None), \
             patch("tts_server.server._load_voice_config", return_value=mock_cfg), \
             patch("tts_server.server._get_dlq_store") as mock_dlq:
            mock_dlq.return_value.stats.return_value = {"pending": 3}
            with TestClient(app) as client:
                r = client.get("/chorus/hud")

        assert r.status_code == 200
        data = r.json()
        assert data["severity"] == "warn"
        assert data["dlq_pending"] == 3

    def test_model_loading_returns_200(self):
        """모델 아직 로딩 중에도 200 반환 (stable fields)."""
        from unittest.mock import patch, MagicMock
        from tts_server.server import app
        from hook_voice.config import Config, SttConfig

        mock_cfg = MagicMock(spec=Config)
        mock_cfg.auto_speak = True
        mock_cfg.voice_mode = "normal"
        mock_cfg.hud = MagicMock()
        mock_cfg.hud.max_label_chars = 50
        mock_cfg.hud.snapshot_path = None
        mock_cfg.stt = SttConfig(enabled=False)

        with patch("tts_server.server._model", new=None), \
             patch("tts_server.server._stt_listener", new=None), \
             patch("tts_server.server._load_voice_config", return_value=mock_cfg), \
             patch("tts_server.server._get_dlq_store") as mock_dlq:
            mock_dlq.return_value.stats.return_value = {"pending": 0}
            with TestClient(app) as client:
                r = client.get("/chorus/hud")

        assert r.status_code == 200
        data = r.json()
        assert "label" in data
        assert "auto_speak" in data

    def test_last_event_and_suggestion_null(self):
        """last_event와 suggestion은 초기엔 None."""
        from unittest.mock import patch, MagicMock
        from tts_server.server import app
        from hook_voice.config import Config, SttConfig

        mock_cfg = MagicMock(spec=Config)
        mock_cfg.auto_speak = True
        mock_cfg.voice_mode = "normal"
        mock_cfg.hud = MagicMock()
        mock_cfg.hud.max_label_chars = 50
        mock_cfg.hud.snapshot_path = None
        mock_cfg.stt = SttConfig(enabled=False)

        with patch("tts_server.server._model", new=object()), \
             patch("tts_server.server._stt_listener", new=None), \
             patch("tts_server.server._load_voice_config", return_value=mock_cfg), \
             patch("tts_server.server._get_dlq_store") as mock_dlq:
            mock_dlq.return_value.stats.return_value = {"pending": 0}
            with TestClient(app) as client:
                r = client.get("/chorus/hud")

        assert r.status_code == 200
        data = r.json()
        assert data["last_event"] is None
        assert data["suggestion"] is None

    def test_severity_ok_when_dlq_empty(self):
        """DLQ pending = 0 이면 severity='ok'."""
        from unittest.mock import patch, MagicMock
        from tts_server.server import app
        from hook_voice.config import Config, SttConfig

        mock_cfg = MagicMock(spec=Config)
        mock_cfg.auto_speak = True
        mock_cfg.voice_mode = "normal"
        mock_cfg.hud = MagicMock()
        mock_cfg.hud.max_label_chars = 50
        mock_cfg.hud.snapshot_path = None
        mock_cfg.stt = SttConfig(enabled=False)

        with patch("tts_server.server._model", new=object()), \
             patch("tts_server.server._stt_listener", new=None), \
             patch("tts_server.server._load_voice_config", return_value=mock_cfg), \
             patch("tts_server.server._get_dlq_store") as mock_dlq:
            mock_dlq.return_value.stats.return_value = {"pending": 0}
            with TestClient(app) as client:
                r = client.get("/chorus/hud")

        assert r.status_code == 200
        assert r.json()["severity"] == "ok"

    def test_label_within_max_chars(self):
        """label은 max_label_chars(50) 이내."""
        from unittest.mock import patch, MagicMock
        from tts_server.server import app
        from hook_voice.config import Config, SttConfig

        mock_cfg = MagicMock(spec=Config)
        mock_cfg.auto_speak = True
        mock_cfg.voice_mode = "normal"
        mock_cfg.hud = MagicMock()
        mock_cfg.hud.max_label_chars = 50
        mock_cfg.hud.snapshot_path = None
        mock_cfg.stt = SttConfig(enabled=False)

        with patch("tts_server.server._model", new=object()), \
             patch("tts_server.server._stt_listener", new=None), \
             patch("tts_server.server._load_voice_config", return_value=mock_cfg), \
             patch("tts_server.server._get_dlq_store") as mock_dlq:
            mock_dlq.return_value.stats.return_value = {"pending": 0}
            with TestClient(app) as client:
                r = client.get("/chorus/hud")

        assert r.status_code == 200
        label = r.json()["label"]
        assert len(label) <= 50
