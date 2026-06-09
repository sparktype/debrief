# server.py 단위 테스트 — 로그·STT·메트릭·DLQ 검증
import os
import time
from unittest.mock import AsyncMock

from tts_server.server import _log
from tts_server.supervisor import _do_cleanup


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
