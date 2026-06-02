# hook_voice/llm_client.py
# HMG Hub LLM 클라이언트 — OpenAI 호환 및 Gemini generateContent 엔드포인트 지원
import logging
import os
import httpx

from .config import load_config
from .observability.circuit_breaker import get_circuit_breaker

DEFAULT_MODEL = "gemini-3.5-flash"

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


def _to_gemini_body(messages: list[dict], **kwargs) -> dict:
    """OpenAI messages 형식을 Gemini generateContent 바디로 변환."""
    system_parts: list[dict] = []
    contents: list[dict] = []

    for msg in messages:
        role, content = msg["role"], msg["content"]
        if role == "system":
            system_parts.append({"text": content})
        else:
            gemini_role = "model" if role == "assistant" else "user"
            contents.append({"role": gemini_role, "parts": [{"text": content}]})

    body: dict = {"contents": contents}
    if system_parts:
        body["systemInstruction"] = {"parts": system_parts}

    gen_config: dict = {"thinkingConfig": {"thinkingBudget": 0}}
    if "max_completion_tokens" in kwargs:
        gen_config["maxOutputTokens"] = kwargs["max_completion_tokens"]
    if "max_tokens" in kwargs:
        gen_config["maxOutputTokens"] = kwargs["max_tokens"]
    if "temperature" in kwargs:
        gen_config["temperature"] = kwargs["temperature"]
    body["generationConfig"] = gen_config

    return body


async def _do_gemini_completion(messages: list[dict], model: str, **kwargs) -> str:
    """Gemini generateContent 엔드포인트 호출."""
    base_url = os.environ.get("HUB_BASE_URL", "").rstrip("/")
    url = f"{base_url}/models/{model}:generateContent"
    body = _to_gemini_body(messages, **kwargs)

    async with httpx.AsyncClient(
        headers=_make_headers(),
        verify=_verify_tls(),
        timeout=30.0,
    ) as client:
        resp = await client.post(url, json=body)
        resp.raise_for_status()
        candidate = resp.json()["candidates"][0]
        parts = candidate.get("content", {}).get("parts")
        if not parts:
            _log.warning("Gemini 응답에 parts 없음 (finishReason=%s)", candidate.get("finishReason"))
            return ""
        return parts[0]["text"].strip()


async def _do_chat_completion(messages: list[dict], model: str, **kwargs) -> str:
    """OpenAI /chat/completions 엔드포인트 호출."""
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
    """LLM chat completion — 모델명에 따라 Gemini / OpenAI 엔드포인트 자동 라우팅."""
    api_key = os.environ.get("HUB_API_KEY", "")
    if not api_key:
        _log.warning("HUB_API_KEY 미설정 — LLM 호출 건너뜀")
        return ""

    _do = _do_gemini_completion if model.startswith("gemini") else _do_chat_completion

    cb = get_circuit_breaker("llm_api")
    try:
        result = await cb.call(_do, messages, model, fallback="", **kwargs)
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
