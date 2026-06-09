# supertonic_mlx_server의 텍스트 전처리 함수 단위 테스트
import sys
import types

# supertonic_mlx 없는 CI 환경에서도 통과하도록 stub
stub = types.ModuleType("supertonic_mlx")
stub.SupertonicMLX = None
sys.modules.setdefault("supertonic_mlx", stub)

from tts_server.supertonic_mlx_server import _preprocess
import tts_server.supertonic_mlx_server as srv


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
        """lifespan 없이 /v1/health는 항상 200을 반환한다."""
        from fastapi.testclient import TestClient
        # TestClient를 context manager 없이 생성하면 lifespan 실행 안 됨
        client = TestClient(srv.app, raise_server_exceptions=False)
        r = client.get("/v1/health")
        assert r.status_code == 200
        assert r.json()["status"] == "ok"

    def test_tts_returns_503_when_model_not_loaded(self):
        """모델 로드 전 /v1/tts 호출 시 503을 반환한다."""
        from fastapi.testclient import TestClient
        original = srv._model
        srv._model = None
        try:
            # context manager 없이 생성하면 lifespan 실행 안 됨
            client = TestClient(srv.app, raise_server_exceptions=False)
            r = client.post("/v1/tts", json={"text": "테스트"})
            assert r.status_code == 503
        finally:
            srv._model = original
