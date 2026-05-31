# hook_voice/llm_client.py
# HMG Hub LLM 클라이언트 — httpx AsyncClient 기반
import logging
import os
import httpx

from .config import load_config
from .observability.circuit_breaker import get_circuit_breaker

DEFAULT_MODEL = "gpt-5.4"

_log = logging.getLogger(__name__)


def _make_headers() -> dict[str, str]:
    api_key = os.environ.get("HUB_API_KEY", "")
    project_id = os.environ.get("HUB_PROJECT_ID", "")
    headers = {"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"}
    if project_id:
        headers["X-Project-Id"] = project_id
    return headers


def _verify_tls() -> bool:
    try:
        return not load_config().allow_insecure_tls
    except Exception:
        return False


async def _do_chat_completion(
    messages: list[dict],
    model: str,
    **kwargs,
) -> str:
    """실제 HTTP 호출. chat_completion의 CB 내부 실행 함수."""
    base_url = os.environ.get("HUB_BASE_URL", "")
    async with httpx.AsyncClient(
        base_url=base_url,
        headers=_make_headers(),
        verify=_verify_tls(),
        timeout=30.0,
    ) as client:
        resp = await client.post(
            "/chat/completions",
            json={"model": model, "messages": messages, **kwargs},
        )
        resp.raise_for_status()
        return resp.json()["choices"][0]["message"]["content"].strip()


async def chat_completion(
    messages: list[dict],
    model: str = DEFAULT_MODEL,
    **kwargs,
) -> str:
    """OpenAI 호환 chat completion — 응답 텍스트 반환, 실패 시 빈 문자열."""
    api_key = os.environ.get("HUB_API_KEY", "")
    if not api_key:
        _log.warning("HUB_API_KEY 미설정 — LLM 호출 건너뜀")
        return ""

    cb = get_circuit_breaker("llm_api")
    try:
        result = await cb.call(_do_chat_completion, messages, model, fallback="", **kwargs)
        return result or ""
    except httpx.TimeoutException as e:
        _log.warning("LLM timeout: %s", type(e).__name__)
        return ""
    except httpx.ConnectError as e:
        _log.warning("LLM connect error: %s", type(e).__name__)
        return ""
    except httpx.HTTPStatusError as e:
        _log.warning("LLM HTTP error %s: %.100s", e.response.status_code, e.response.text)
        return ""
    except Exception as e:
        _log.warning("LLM unexpected error: %s", type(e).__name__)
        return ""
