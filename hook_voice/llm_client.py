# hook_voice/llm_client.py
# HMG Hub LLM 클라이언트 — httpx AsyncClient 기반
import logging
import os
import httpx

DEFAULT_MODEL = "gpt-5.4"

_log = logging.getLogger(__name__)


def _make_headers() -> dict[str, str]:
    api_key = os.environ.get("HUB_API_KEY", "")
    project_id = os.environ.get("HUB_PROJECT_ID", "")
    headers = {"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"}
    if project_id:
        headers["X-Project-Id"] = project_id
    return headers


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
    base_url = os.environ.get("HUB_BASE_URL", "")
    async with httpx.AsyncClient(
        base_url=base_url,
        headers=_make_headers(),
        verify=False,
        timeout=30.0,
    ) as client:
        try:
            resp = await client.post(
                "/chat/completions",
                json={"model": model, "messages": messages, **kwargs},
            )
            resp.raise_for_status()
            return resp.json()["choices"][0]["message"]["content"].strip()
        except Exception:
            return ""
