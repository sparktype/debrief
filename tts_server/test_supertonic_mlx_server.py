# supertonic_mlx_server의 텍스트 전처리 함수 단위 테스트
import sys
import types

# supertonic_mlx 없는 CI 환경에서도 통과하도록 stub
stub = types.ModuleType("supertonic_mlx")
stub.SupertonicMLX = None
sys.modules.setdefault("supertonic_mlx", stub)

from tts_server.supertonic_mlx_server import _preprocess


class TestPreprocess:
    def test_docker_replaced(self):
        assert _preprocess("Docker") == "도커"

    def test_case_insensitive(self):
        assert _preprocess("docker") == "도커"
        assert _preprocess("DOCKER") == "도커"

    def test_unknown_word_unchanged(self):
        assert "SomeWord" in _preprocess("SomeWord")

    def test_mixed_sentence(self):
        result = _preprocess("API와 Docker를 사용합니다")
        assert "에이피아이" in result
        assert "도커" in result
