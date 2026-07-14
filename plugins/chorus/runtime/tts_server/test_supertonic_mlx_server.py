# server.py 텍스트 전처리 및 TTS 엔드포인트 단위 테스트
import sys
import types

# supertonic_mlx 없는 CI 환경에서도 통과하도록 stub
stub = types.ModuleType("supertonic_mlx")
stub.SupertonicMLX = None
sys.modules.setdefault("supertonic_mlx", stub)
# soundfile stub
sf_stub = types.ModuleType("soundfile")
sf_stub.write = lambda *a, **kw: None
sys.modules.setdefault("soundfile", sf_stub)

from tts_server.server import _preprocess
import tts_server.server as srv


class TestPreprocess:
    def test_docker_replaced(self):
        assert _preprocess("Docker") == "도커"

    def test_case_insensitive(self):
        assert _preprocess("docker") == "도커"
        assert _preprocess("DOCKER") == "도커"

    def test_unknown_word_unchanged(self):
        assert _preprocess("SomeWord") == "SomeWord"

    def test_mixed_sentence(self):
        result = _preprocess("API와 Docker를 사용합니다")
        assert "에이피아이" in result
        assert "도커" in result


class TestHTTPEndpoints:
    def test_health_returns_ok(self):
        """/health는 모델 로드 여부와 무관하게 항상 200을 반환한다."""
        from fastapi.testclient import TestClient
        client = TestClient(srv.app, raise_server_exceptions=False)
        r = client.get("/health")
        assert r.status_code == 200
        assert r.json()["status"] == "ok"

    def test_v1_health_returns_503_when_model_not_loaded(self):
        """모델 로드 전 /v1/health는 503을 반환한다."""
        from fastapi.testclient import TestClient
        original = srv._model
        srv._model = None
        try:
            client = TestClient(srv.app, raise_server_exceptions=False)
            r = client.get("/v1/health")
            assert r.status_code == 503
        finally:
            srv._model = original

    def test_tts_returns_503_when_model_not_loaded(self):
        """모델 로드 전 /v1/tts 호출 시 503을 반환한다."""
        from fastapi.testclient import TestClient
        original = srv._model
        srv._model = None
        try:
            client = TestClient(srv.app, raise_server_exceptions=False)
            r = client.post("/v1/tts", json={"text": "테스트"})
            assert r.status_code == 503
        finally:
            srv._model = original
