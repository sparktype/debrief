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
