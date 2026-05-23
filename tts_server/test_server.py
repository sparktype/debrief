# tts_server 발음 보정 함수 단위 테스트
import sys
import os

# mlx 없는 환경에서도 테스트 가능하도록 모듈 import 전 패치
sys.modules.setdefault("mlx_audio", type(sys)("mlx_audio"))
sys.modules.setdefault("mlx_audio.tts", type(sys)("mlx_audio.tts"))
sys.modules.setdefault("mlx_audio.tts.generate", type(sys)("mlx_audio.tts.generate"))
sys.modules.setdefault("mlx_audio.tts.utils", type(sys)("mlx_audio.tts.utils"))

from tts_server.server import _preprocess_for_tts


class TestTechPhonetics:
    def test_exact_key_match(self):
        assert _preprocess_for_tts("Docker") == "도커"

    def test_lowercase(self):
        assert _preprocess_for_tts("docker") == "도커"

    def test_uppercase(self):
        assert _preprocess_for_tts("DOCKER") == "도커"

    def test_mixed_sentence(self):
        result = _preprocess_for_tts("API와 Docker를 사용합니다")
        assert "에이피아이" in result
        assert "도커" in result

    def test_unknown_word_unchanged(self):
        result = _preprocess_for_tts("SomeUnknownWord")
        assert "SomeUnknownWord" in result


import datetime
from tts_server.server import _log


class TestStructuredLog:
    def test_info_prefix(self, capsys):
        _log("INFO", "서버 시작")
        captured = capsys.readouterr()
        assert "[INFO]" in captured.out
        assert "서버 시작" in captured.out

    def test_error_prefix(self, capsys):
        _log("ERROR", "오류 발생")
        captured = capsys.readouterr()
        assert "[ERROR]" in captured.out

    def test_timestamp_included(self, capsys):
        _log("INFO", "타임스탬프 확인")
        captured = capsys.readouterr()
        import re
        assert re.search(r"\d{4}-\d{2}-\d{2}", captured.out)


import os
import time
import tempfile
import subprocess


class TestSpoolCleanup:
    def test_old_files_removed_on_start(self, tmp_path):
        """데몬 시작 시 5분 초과 파일이 삭제되어야 한다."""
        spool = tmp_path / "tts-spool"
        spool.mkdir()

        # 6분 전 파일 생성
        old_file = spool / "1000000.wav"
        old_file.write_bytes(b"old")
        old_time = time.time() - 360  # 6분 전
        os.utime(str(old_file), (old_time, old_time))

        # 최신 파일 생성
        new_file = spool / "9999999.wav"
        new_file.write_bytes(b"new")

        # bash 스크립트 내 _cleanup_stale 로직을 직접 실행
        result = subprocess.run(
            ["bash", "-c", f"""
SPOOL="{spool}"
MAX_AGE=300
find "$SPOOL" \\( -name "*.wav" -o -name "*.mp3" \\) -mmin +$((MAX_AGE/60)) -delete 2>/dev/null || true
"""],
            capture_output=True
        )
        assert result.returncode == 0
        assert not old_file.exists(), "6분 전 파일이 삭제되어야 함"
        assert new_file.exists(), "최신 파일은 유지되어야 함"

    def test_max_10_files_enforced(self, tmp_path):
        """스풀에 파일이 10개 초과 시 오래된 것이 제거되어야 한다."""
        spool = tmp_path / "tts-spool"
        spool.mkdir()

        # 12개 파일 생성 (epoch_ms 기준 오름차순)
        for i in range(12):
            (spool / f"{1000 + i}.wav").write_bytes(b"x")

        result = subprocess.run(
            ["bash", "-c", f"""
SPOOL="{spool}"
MAX_FILES=10
files=($(ls -1 "$SPOOL"/*.wav "$SPOOL"/*.mp3 2>/dev/null | sort))
count=${{#files[@]}}
if (( count > MAX_FILES )); then
  excess=$(( count - MAX_FILES ))
  for f in "${{files[@]:0:$excess}}"; do
    rm -f "$f" "${{f%.*}}.meta"
  done
fi
"""],
            capture_output=True
        )
        assert result.returncode == 0
        remaining = list(spool.glob("*.wav"))
        assert len(remaining) == 10, f"10개만 남아야 하는데 {len(remaining)}개"


from fastapi.testclient import TestClient


class TestModelLoadingFailure:
    def test_health_returns_error_detail_when_load_fails(self):
        """모델 로딩 실패 시 /health가 503 + error detail 반환해야 한다."""
        import tts_server.server as srv
        srv._model_error.set()
        srv._model_error_message = "테스트 오류: 모델 파일 없음"
        srv._model_ready.clear()
        try:
            client = TestClient(srv.app, raise_server_exceptions=False)
            resp = client.get("/health")
            assert resp.status_code == 503
            data = resp.json()
            assert data["status"] == "error"
            assert "테스트 오류" in data.get("detail", "")
        finally:
            srv._model_error.clear()
            srv._model_error_message = ""
