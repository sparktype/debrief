# TypeScript → Python(hook_voice) 전환 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 기존 TypeScript/Node.js hook CLI를 `hook_voice` Python 패키지로 완전히 대체하여 단일 Python 스택을 구성한다.

**Architecture:** `hook_voice/` 패키지를 새로 생성하고 `src/*.ts` 로직을 asyncio 기반 Python으로 재구현한다. MCP 서버는 제거하고 hook CLI만 유지한다. `tts_server/`는 변경하지 않는다.

**Tech Stack:** Python 3.13, asyncio, edge-tts 7.2.8, httpx 0.28.1, pytest 9.0.3, pytest-asyncio

---

## 파일 구조

| 파일 | 역할 |
|------|------|
| `hook_voice/__init__.py` | 패키지 마커 |
| `hook_voice/__main__.py` | `python -m hook_voice <subcommand>` 진입점 |
| `hook_voice/config.py` | `.voice-persona.json` 로더, 기본값 관리 |
| `hook_voice/llm_client.py` | HMG Hub API httpx 클라이언트 |
| `hook_voice/last_message.py` | 마지막 TTS 텍스트 파일 영속화 |
| `hook_voice/summarizer.py` | LLM 요약 + 규칙 기반 폴백 |
| `hook_voice/voice_router.py` | agentType → Supertonic voice ID |
| `hook_voice/skill_recommender.py` | transcript 분석 → LLM 스킬 추천 + 쿨다운 |
| `hook_voice/player.py` | EdgeTTS → spool enqueue, speak_hook/speak_agent |
| `hook_voice/hook_handlers.py` | 각 subcommand 구현 함수 |
| `pytest.ini` | asyncio_mode = auto 설정 |
| `tests/test_config.py` | config 테스트 |
| `tests/test_llm_client.py` | llm_client 테스트 |
| `tests/test_last_message.py` | last_message 테스트 |
| `tests/test_summarizer.py` | summarizer 테스트 |
| `tests/test_voice_router.py` | voice_router 테스트 |
| `tests/test_skill_recommender.py` | skill_recommender 테스트 |
| `tests/test_player.py` | player 테스트 |
| `tests/test_hook_handlers.py` | hook_handlers 테스트 |

**환경:** 모든 명령은 `tts-venv/bin/python` / `tts-venv/bin/pytest` 사용. 프로젝트 루트 `/Users/hmc7102758/Develop/Workspaces/chorus` 기준.

---

### Task 1: 프로젝트 스캐폴딩

**Files:**
- Create: `hook_voice/__init__.py`
- Create: `pytest.ini`
- Modify: `tts-venv` (pytest-asyncio 설치)

- [ ] **Step 1: hook_voice 패키지 디렉토리 생성**

```bash
mkdir -p hook_voice
touch hook_voice/__init__.py
```

- [ ] **Step 2: pytest-asyncio 설치**

```bash
tts-venv/bin/pip install pytest-asyncio
```

Expected: `Successfully installed pytest-asyncio-x.x.x`

- [ ] **Step 3: pytest.ini 생성**

```ini
[pytest]
asyncio_mode = auto
```

- [ ] **Step 4: 설치 확인**

```bash
tts-venv/bin/pytest --version
tts-venv/bin/python -c "import pytest_asyncio; print(pytest_asyncio.__version__)"
```

Expected: pytest 버전과 pytest-asyncio 버전 출력

- [ ] **Step 5: 커밋**

```bash
git add hook_voice/__init__.py pytest.ini
git commit -m "chore: hook_voice 패키지 스캐폴딩 및 pytest-asyncio 설정"
```

---

### Task 2: hook_voice/config.py

**Files:**
- Create: `hook_voice/config.py`
- Create: `tests/test_config.py`

- [ ] **Step 1: 실패하는 테스트 작성**

```python
# tests/test_config.py
import json
import pytest
from pathlib import Path
from hook_voice.config import Config, load_config

def test_load_config_returns_defaults_when_no_file(tmp_path):
    cfg = load_config(tmp_path / "nonexistent.json")
    assert cfg.auto_speak is True
    assert cfg.min_chars == 50
    assert cfg.voice == "Sohee"
    assert cfg.summary_model == "gpt-5.4"
    assert cfg.tts_speed == 1.2
    assert cfg.tts_instruct == "밝고 활기차게 말해주세요"
    assert cfg.skill_cooldown_minutes == 30
    assert cfg.supertonic_port == 7788
    assert cfg.edge_timeout_ms == 10000
    assert cfg.supertonic_timeout_ms == 20000

def test_load_config_merges_file_values(tmp_path):
    cfg_file = tmp_path / "config.json"
    cfg_file.write_text(json.dumps({"autoSpeak": False, "minChars": 100, "ttsSpeed": 1.5}))
    cfg = load_config(cfg_file)
    assert cfg.auto_speak is False
    assert cfg.min_chars == 100
    assert cfg.tts_speed == 1.5
    assert cfg.voice == "Sohee"  # 기본값 유지

def test_load_config_returns_defaults_on_invalid_json(tmp_path):
    cfg_file = tmp_path / "config.json"
    cfg_file.write_text("not json{{")
    cfg = load_config(cfg_file)
    assert cfg.auto_speak is True
```

- [ ] **Step 2: 테스트 실패 확인**

```bash
tts-venv/bin/pytest tests/test_config.py -v
```

Expected: `ImportError: No module named 'hook_voice.config'`

- [ ] **Step 3: config.py 구현**

```python
# hook_voice/config.py
# 사용자 설정 파일 로더 및 기본값 관리
import json
from dataclasses import dataclass
from pathlib import Path

_DEFAULT_CONFIG_PATH = Path(__file__).parent.parent / ".voice-persona.json"

_KEY_MAP = {
    "autoSpeak": "auto_speak",
    "minChars": "min_chars",
    "voice": "voice",
    "summaryModel": "summary_model",
    "ttsSpeed": "tts_speed",
    "ttsInstruct": "tts_instruct",
    "skillCooldownMinutes": "skill_cooldown_minutes",
    "supertonicPort": "supertonic_port",
    "edgeTimeoutMs": "edge_timeout_ms",
    "supertonicTimeoutMs": "supertonic_timeout_ms",
}


@dataclass
class Config:
    auto_speak: bool = True
    min_chars: int = 50
    voice: str = "Sohee"
    summary_model: str = "gpt-5.4"
    tts_speed: float = 1.2
    tts_instruct: str = "밝고 활기차게 말해주세요"
    skill_cooldown_minutes: int = 30
    supertonic_port: int = 7788
    edge_timeout_ms: int = 10000
    supertonic_timeout_ms: int = 20000


def load_config(path: Path | None = None) -> Config:
    target = path or _DEFAULT_CONFIG_PATH
    if not target.exists():
        return Config()
    try:
        data = json.loads(target.read_text(encoding="utf-8"))
        kwargs = {py_k: data[json_k] for json_k, py_k in _KEY_MAP.items() if json_k in data}
        return Config(**kwargs)
    except Exception:
        return Config()
```

- [ ] **Step 4: 테스트 통과 확인**

```bash
tts-venv/bin/pytest tests/test_config.py -v
```

Expected: `3 passed`

- [ ] **Step 5: 커밋**

```bash
git add hook_voice/config.py tests/test_config.py
git commit -m "feat: hook_voice/config.py — Config dataclass + load_config"
```

---

### Task 3: hook_voice/llm_client.py

**Files:**
- Create: `hook_voice/llm_client.py`
- Create: `tests/test_llm_client.py`

- [ ] **Step 1: 실패하는 테스트 작성**

```python
# tests/test_llm_client.py
import pytest
import httpx
from unittest.mock import AsyncMock, patch, MagicMock
from hook_voice.llm_client import chat_completion, DEFAULT_MODEL

async def test_chat_completion_returns_content(respx_mock):
    # httpx mock — respx 없이 unittest.mock으로 처리
    response_json = {
        "choices": [{"message": {"content": "요약 결과"}}]
    }
    with patch("hook_voice.llm_client.httpx.AsyncClient") as mock_cls:
        mock_client = AsyncMock()
        mock_cls.return_value.__aenter__ = AsyncMock(return_value=mock_client)
        mock_cls.return_value.__aexit__ = AsyncMock(return_value=False)
        mock_resp = MagicMock()
        mock_resp.json.return_value = response_json
        mock_resp.raise_for_status = MagicMock()
        mock_client.post = AsyncMock(return_value=mock_resp)

        result = await chat_completion(
            messages=[{"role": "user", "content": "test"}],
            model=DEFAULT_MODEL,
        )
        assert result == "요약 결과"

async def test_chat_completion_returns_empty_on_error():
    with patch("hook_voice.llm_client.httpx.AsyncClient") as mock_cls:
        mock_client = AsyncMock()
        mock_cls.return_value.__aenter__ = AsyncMock(return_value=mock_client)
        mock_cls.return_value.__aexit__ = AsyncMock(return_value=False)
        mock_client.post = AsyncMock(side_effect=httpx.ConnectError("connection refused"))

        result = await chat_completion(
            messages=[{"role": "user", "content": "test"}],
        )
        assert result == ""
```

- [ ] **Step 2: 테스트 실패 확인**

```bash
tts-venv/bin/pytest tests/test_llm_client.py -v
```

Expected: `ImportError: No module named 'hook_voice.llm_client'`

- [ ] **Step 3: llm_client.py 구현**

```python
# hook_voice/llm_client.py
# HMG Hub LLM 클라이언트 — httpx AsyncClient 기반
import os
import httpx

DEFAULT_MODEL = "gpt-5.4"


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
```

- [ ] **Step 4: 테스트 통과 확인**

```bash
tts-venv/bin/pytest tests/test_llm_client.py -v
```

Expected: `2 passed`

- [ ] **Step 5: 커밋**

```bash
git add hook_voice/llm_client.py tests/test_llm_client.py
git commit -m "feat: hook_voice/llm_client.py — httpx 기반 HMG Hub API 클라이언트"
```

---

### Task 4: hook_voice/last_message.py

**Files:**
- Create: `hook_voice/last_message.py`
- Create: `tests/test_last_message.py`

- [ ] **Step 1: 실패하는 테스트 작성**

```python
# tests/test_last_message.py
import pytest
from pathlib import Path
from hook_voice.last_message import save_last_message, load_last_message

def test_save_and_load(tmp_path, monkeypatch):
    monkeypatch.setenv("VOICE_PERSONA_DATA_DIR", str(tmp_path))
    save_last_message("안녕하세요")
    assert load_last_message() == "안녕하세요"

def test_load_returns_none_when_no_file(tmp_path, monkeypatch):
    monkeypatch.setenv("VOICE_PERSONA_DATA_DIR", str(tmp_path))
    assert load_last_message() is None

def test_save_overwrites_previous(tmp_path, monkeypatch):
    monkeypatch.setenv("VOICE_PERSONA_DATA_DIR", str(tmp_path))
    save_last_message("첫 번째")
    save_last_message("두 번째")
    assert load_last_message() == "두 번째"
```

- [ ] **Step 2: 테스트 실패 확인**

```bash
tts-venv/bin/pytest tests/test_last_message.py -v
```

Expected: `ImportError: No module named 'hook_voice.last_message'`

- [ ] **Step 3: last_message.py 구현**

```python
# hook_voice/last_message.py
# 마지막 TTS 재생 텍스트 저장 및 읽기
import os
from pathlib import Path


def _get_data_dir() -> Path:
    env = os.environ.get("VOICE_PERSONA_DATA_DIR")
    return Path(env) if env else Path.home() / ".local" / "share" / "voice-persona"


def _get_last_msg_file() -> Path:
    return _get_data_dir() / "last-message.txt"


def save_last_message(text: str) -> None:
    try:
        f = _get_last_msg_file()
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_text(text, encoding="utf-8")
    except Exception:
        pass


def load_last_message() -> str | None:
    try:
        f = _get_last_msg_file()
        return f.read_text(encoding="utf-8") if f.exists() else None
    except Exception:
        return None
```

- [ ] **Step 4: 테스트 통과 확인**

```bash
tts-venv/bin/pytest tests/test_last_message.py -v
```

Expected: `3 passed`

- [ ] **Step 5: 커밋**

```bash
git add hook_voice/last_message.py tests/test_last_message.py
git commit -m "feat: hook_voice/last_message.py — 마지막 TTS 텍스트 영속화"
```

---

### Task 5: hook_voice/summarizer.py

**Files:**
- Create: `hook_voice/summarizer.py`
- Create: `tests/test_summarizer.py`

- [ ] **Step 1: 실패하는 테스트 작성**

```python
# tests/test_summarizer.py
import pytest
from unittest.mock import patch, AsyncMock
from hook_voice.summarizer import strip_markdown, sanitize_for_speech, extract_summary, extract_one_liner

def test_strip_markdown_removes_code_blocks():
    result = strip_markdown("앞\n```python\ncode\n```\n뒤")
    assert "[코드 생략]" in result
    assert "앞" in result

def test_strip_markdown_removes_headers():
    assert strip_markdown("# 제목") == "제목"

def test_sanitize_for_speech_removes_special_chars():
    result = sanitize_for_speech("안녕 *world* 🎉")
    assert "🎉" not in result
    assert "안녕" in result

async def test_extract_summary_uses_llm():
    with patch("hook_voice.summarizer.chat_completion", new=AsyncMock(return_value="LLM 요약")) as mock:
        result = await extract_summary("긴 텍스트입니다.")
        assert result == "LLM 요약"
        mock.assert_called_once()

async def test_extract_summary_falls_back_on_empty_llm():
    with patch("hook_voice.summarizer.chat_completion", new=AsyncMock(return_value="")):
        result = await extract_summary("첫 문장. 두 번째 문장. 세 번째 문장.")
        assert len(result) > 0

async def test_extract_one_liner_sanitizes_result():
    with patch("hook_voice.summarizer.chat_completion", new=AsyncMock(return_value="결과 *완료*")):
        result = await extract_one_liner("작업 텍스트")
        assert "*" not in result

async def test_extract_summary_returns_empty_for_blank():
    result = await extract_summary("   ")
    assert result == ""
```

- [ ] **Step 2: 테스트 실패 확인**

```bash
tts-venv/bin/pytest tests/test_summarizer.py -v
```

Expected: `ImportError: No module named 'hook_voice.summarizer'`

- [ ] **Step 3: summarizer.py 구현**

```python
# hook_voice/summarizer.py
# LLM 기반 텍스트 요약기 — HMG Hub API 사용, 실패 시 규칙 기반 폴백
import re
from .llm_client import chat_completion, DEFAULT_MODEL

_SUMMARY_SYSTEM = (
    "주어진 텍스트의 핵심 결론이나 중요한 내용을 1~3문장으로 요약하세요. "
    "코드·마크다운 기호 없이 자연스러운 한국어 평문으로 작성합니다."
)
_ONE_LINER_SYSTEM = "작업 결과를 한 문장(25자 이내)으로 요약하세요. 마침표·특수기호 없이, 간결하게."


def strip_markdown(text: str) -> str:
    text = re.sub(r"```[\s\S]*?```", "[코드 생략]", text)
    text = re.sub(r"`[^`]+`", "", text)
    text = re.sub(r"^\|.+$", "", text, flags=re.MULTILINE)
    text = re.sub(r"#{1,6} (.+)", r"\1", text)
    text = re.sub(r"^[-*]{3,}$", "", text, flags=re.MULTILINE)
    text = re.sub(r"\*{1,3}([^*\n]+)\*{1,3}", r"\1", text)
    text = re.sub(r"_([^_\n]+)_", r"\1", text)
    text = re.sub(r"\n+", " ", text)
    return text.strip()


def sanitize_for_speech(text: str) -> str:
    text = re.sub(r"[^\w\s,.!?。:]", " ", text)
    return re.sub(r"\s+", " ", text).strip()


def _fallback(text: str, sentence_count: int = 3) -> str:
    cleaned = strip_markdown(text)
    if not cleaned:
        return ""
    sentences = [s.strip() for s in re.split(r"(?<=[.!?。])\s*", cleaned) if len(s.strip()) > 1]
    return " ".join(sentences[-sentence_count:]) if sentences else cleaned


async def extract_summary(text: str, model: str = DEFAULT_MODEL) -> str:
    if not text.strip():
        return ""
    result = await chat_completion(
        messages=[
            {"role": "system", "content": _SUMMARY_SYSTEM},
            {"role": "user", "content": strip_markdown(text)},
        ],
        model=model,
        max_completion_tokens=200,
        temperature=0.3,
    )
    return result or _fallback(text)


async def extract_one_liner(text: str, model: str = DEFAULT_MODEL) -> str:
    if not text.strip():
        return ""
    result = await chat_completion(
        messages=[
            {"role": "system", "content": _ONE_LINER_SYSTEM},
            {"role": "user", "content": strip_markdown(text)[:2000]},
        ],
        model=model,
        max_completion_tokens=60,
        temperature=0.3,
    )
    return sanitize_for_speech(result or _fallback(text, 1))
```

- [ ] **Step 4: 테스트 통과 확인**

```bash
tts-venv/bin/pytest tests/test_summarizer.py -v
```

Expected: `7 passed`

- [ ] **Step 5: 커밋**

```bash
git add hook_voice/summarizer.py tests/test_summarizer.py
git commit -m "feat: hook_voice/summarizer.py — LLM 요약 + 규칙 기반 폴백"
```

---

### Task 6: hook_voice/voice_router.py

**Files:**
- Create: `hook_voice/voice_router.py`
- Create: `tests/test_voice_router.py`

- [ ] **Step 1: 실패하는 테스트 작성**

```python
# tests/test_voice_router.py
import json
import pytest
from pathlib import Path
from hook_voice.voice_router import load_voice_map, resolve_voice, get_agent_label

_SAMPLE_MAP = {
    "supertonic": {"lang": "ko"},
    "voices": {"reviewer": "M2", "planner": "M1", "default": "F1"},
    "categories": {
        "reviewer": ["code-reviewer", "feature-reviewer"],
        "planner": ["planner", "architect"],
    },
}

def test_load_voice_map_returns_fallback_when_no_file(tmp_path):
    vm = load_voice_map(tmp_path / "nonexistent.json")
    assert vm["voices"]["default"] == "F1"

def test_load_voice_map_parses_file(tmp_path):
    f = tmp_path / "voice-map.json"
    f.write_text(json.dumps(_SAMPLE_MAP))
    vm = load_voice_map(f)
    assert vm["voices"]["reviewer"] == "M2"

def test_resolve_voice_matches_category(tmp_path):
    f = tmp_path / "voice-map.json"
    f.write_text(json.dumps(_SAMPLE_MAP))
    vm = load_voice_map(f)
    assert resolve_voice("code-reviewer", vm) == "M2"
    assert resolve_voice("planner", vm) == "M1"

def test_resolve_voice_returns_default_for_unknown(tmp_path):
    f = tmp_path / "voice-map.json"
    f.write_text(json.dumps(_SAMPLE_MAP))
    vm = load_voice_map(f)
    assert resolve_voice("unknown-agent", vm) == "F1"

def test_get_agent_label_known(tmp_path):
    f = tmp_path / "voice-map.json"
    f.write_text(json.dumps(_SAMPLE_MAP))
    vm = load_voice_map(f)
    assert get_agent_label("code-reviewer", vm) == "리뷰어"
    assert get_agent_label("planner", vm) == "플래너"

def test_get_agent_label_unknown(tmp_path):
    f = tmp_path / "voice-map.json"
    f.write_text(json.dumps(_SAMPLE_MAP))
    vm = load_voice_map(f)
    assert get_agent_label("unknown-bot", vm) == "에이전트"
```

- [ ] **Step 2: 테스트 실패 확인**

```bash
tts-venv/bin/pytest tests/test_voice_router.py -v
```

Expected: `ImportError: No module named 'hook_voice.voice_router'`

- [ ] **Step 3: voice_router.py 구현**

```python
# hook_voice/voice_router.py
# 에이전트 타입을 카테고리·Supertonic voice ID로 변환하는 라우터
import json
from pathlib import Path
from typing import TypedDict

_DEFAULT_VOICE_MAP_PATH = Path(__file__).parent.parent / "voice-map.json"

_CATEGORY_LABELS: dict[str, str] = {
    "reviewer": "리뷰어",
    "planner": "플래너",
    "builder": "빌더",
    "tester": "테스터",
    "explorer": "탐색기",
}


class VoiceMap(TypedDict):
    supertonic: dict
    voices: dict[str, str]
    categories: dict[str, list[str]]


_FALLBACK_MAP: VoiceMap = {
    "supertonic": {"lang": "ko"},
    "voices": {"default": "F1"},
    "categories": {},
}


def load_voice_map(path: Path | None = None) -> VoiceMap:
    target = path or _DEFAULT_VOICE_MAP_PATH
    if not target.exists():
        return dict(_FALLBACK_MAP)  # type: ignore[return-value]
    try:
        parsed = json.loads(target.read_text(encoding="utf-8"))
        if not all(k in parsed for k in ("supertonic", "voices", "categories")):
            return dict(_FALLBACK_MAP)  # type: ignore[return-value]
        return parsed
    except Exception:
        return dict(_FALLBACK_MAP)  # type: ignore[return-value]


def resolve_voice(agent_type: str, voice_map: VoiceMap | None = None) -> str:
    m = voice_map or load_voice_map()
    for cat, agents in m["categories"].items():
        if agent_type in agents:
            return m["voices"].get(cat) or m["voices"].get("default", "F1")
    return m["voices"].get("default", "F1")


def get_agent_label(agent_type: str, voice_map: VoiceMap | None = None) -> str:
    m = voice_map or load_voice_map()
    for cat, agents in m["categories"].items():
        if agent_type in agents:
            return _CATEGORY_LABELS.get(cat, "에이전트")
    return "에이전트"
```

- [ ] **Step 4: 테스트 통과 확인**

```bash
tts-venv/bin/pytest tests/test_voice_router.py -v
```

Expected: `6 passed`

- [ ] **Step 5: 커밋**

```bash
git add hook_voice/voice_router.py tests/test_voice_router.py
git commit -m "feat: hook_voice/voice_router.py — agentType → Supertonic voice 라우터"
```

---

### Task 7: hook_voice/skill_recommender.py

**Files:**
- Create: `hook_voice/skill_recommender.py`
- Create: `tests/test_skill_recommender.py`

- [ ] **Step 1: 실패하는 테스트 작성**

```python
# tests/test_skill_recommender.py
import json
import pytest
from pathlib import Path
from unittest.mock import patch, AsyncMock
from hook_voice.skill_recommender import (
    parse_catalog, parse_recommendation, is_in_cooldown,
    load_cooldowns, save_cooldown, recommend_skill,
    read_recent_transcripts,
)

_CATALOG = [
    {"skill": "superpowers:brainstorming", "description": "아이디어를 설계로"},
    {"skill": "superpowers:writing-plans", "description": "구현 계획 작성"},
]

def test_parse_catalog_valid():
    raw = json.dumps(_CATALOG)
    result = parse_catalog(raw)
    assert len(result) == 2
    assert result[0]["skill"] == "superpowers:brainstorming"

def test_parse_catalog_invalid_returns_empty():
    assert parse_catalog("not json") == []
    assert parse_catalog('"string"') == []

def test_parse_recommendation_valid():
    raw = json.dumps({"skill": "superpowers:brainstorming", "reason": "아이디어 정리 중"})
    rec = parse_recommendation(raw, _CATALOG)
    assert rec is not None
    assert rec["skill"] == "superpowers:brainstorming"

def test_parse_recommendation_unknown_skill():
    raw = json.dumps({"skill": "unknown:skill", "reason": "이유"})
    assert parse_recommendation(raw, _CATALOG) is None

def test_is_in_cooldown_true():
    from datetime import datetime, timezone, timedelta
    recent = (datetime.now(timezone.utc) - timedelta(minutes=5)).isoformat()
    assert is_in_cooldown("some-skill", {"some-skill": recent}, cooldown_minutes=30) is True

def test_is_in_cooldown_false_expired():
    from datetime import datetime, timezone, timedelta
    old = (datetime.now(timezone.utc) - timedelta(minutes=60)).isoformat()
    assert is_in_cooldown("some-skill", {"some-skill": old}, cooldown_minutes=30) is False

def test_is_in_cooldown_false_no_entry():
    assert is_in_cooldown("some-skill", {}, cooldown_minutes=30) is False

def test_save_and_load_cooldown(tmp_path, monkeypatch):
    monkeypatch.setenv("VOICE_PERSONA_DATA_DIR", str(tmp_path))
    save_cooldown("superpowers:brainstorming")
    cooldowns = load_cooldowns()
    assert "superpowers:brainstorming" in cooldowns

async def test_recommend_skill_returns_recommendation(tmp_path, monkeypatch):
    monkeypatch.setenv("VOICE_PERSONA_DATA_DIR", str(tmp_path))
    catalog_json = json.dumps(_CATALOG)
    with patch("hook_voice.skill_recommender._CATALOG_FILE") as mock_file:
        mock_file.read_text.return_value = catalog_json
        with patch(
            "hook_voice.skill_recommender.chat_completion",
            new=AsyncMock(return_value=json.dumps({"skill": "superpowers:brainstorming", "reason": "이유"})),
        ):
            rec = await recommend_skill("대화 컨텍스트", bypass_cooldown=True)
            assert rec is not None
            assert rec["skill"] == "superpowers:brainstorming"

def test_read_recent_transcripts_empty_dir(tmp_path):
    result = read_recent_transcripts(transcripts_dir=tmp_path)
    assert result == ""

def test_read_recent_transcripts_nonexistent_dir(tmp_path):
    result = read_recent_transcripts(transcripts_dir=tmp_path / "no-such-dir")
    assert result == ""
```

- [ ] **Step 2: 테스트 실패 확인**

```bash
tts-venv/bin/pytest tests/test_skill_recommender.py -v
```

Expected: `ImportError: No module named 'hook_voice.skill_recommender'`

- [ ] **Step 3: skill_recommender.py 구현**

```python
# hook_voice/skill_recommender.py
# 사용자 transcript 분석 → HMG LLM → 스킬 추천 + 쿨다운 관리
import json
import os
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import TypedDict

from .llm_client import chat_completion, DEFAULT_MODEL

_CATALOG_FILE = Path(__file__).parent.parent / "skills-catalog.json"
_CACHE_TTL = 60.0
_transcript_cache: dict[str, tuple[str, float]] = {}


class SkillEntry(TypedDict):
    skill: str
    description: str


class Recommendation(TypedDict):
    skill: str
    reason: str


def _get_data_dir() -> Path:
    env = os.environ.get("VOICE_PERSONA_DATA_DIR")
    return Path(env) if env else Path.home() / ".local" / "share" / "voice-persona"


def _get_cooldowns_file() -> Path:
    return _get_data_dir() / "skill-cooldowns.json"


def parse_catalog(raw: str) -> list[SkillEntry]:
    try:
        arr = json.loads(raw)
        return arr if isinstance(arr, list) else []
    except Exception:
        return []


def parse_recommendation(raw: str, catalog: list[SkillEntry]) -> Recommendation | None:
    try:
        rec = json.loads(raw)
        if not rec.get("skill"):
            return None
        if not any(s["skill"] == rec["skill"] for s in catalog):
            return None
        return {"skill": rec["skill"], "reason": rec.get("reason", "")}
    except Exception:
        return None


def load_catalog() -> list[SkillEntry]:
    try:
        return parse_catalog(_CATALOG_FILE.read_text(encoding="utf-8"))
    except Exception:
        return []


def _extract_content(raw: object) -> str:
    if isinstance(raw, str):
        return raw[:300]
    if isinstance(raw, list):
        return " ".join(
            b["text"] for b in raw
            if isinstance(b, dict) and isinstance(b.get("text"), str)
        )[:300]
    return ""


def read_recent_transcripts(
    transcripts_dir: Path | None = None,
    max_files: int = 3,
    max_lines_per_file: int = 50,
) -> str:
    dir_ = transcripts_dir or (Path.home() / ".claude" / "transcripts")
    cache_key = str(dir_)
    if cache_key in _transcript_cache:
        data, ts = _transcript_cache[cache_key]
        if time.time() - ts < _CACHE_TTL:
            return data
    if not dir_.exists():
        return ""
    try:
        files = sorted(dir_.glob("*.jsonl"), key=lambda f: f.stat().st_mtime, reverse=True)[:max_files]
        parts: list[str] = []
        for f in files:
            for line in f.read_text(encoding="utf-8").splitlines()[-max_lines_per_file:]:
                try:
                    entry = json.loads(line)
                    content = _extract_content(entry.get("content", ""))
                    if entry.get("type") == "user":
                        parts.append(f"User: {content}")
                    elif entry.get("type") == "assistant":
                        parts.append(f"Assistant: {content}")
                except Exception:
                    pass
            parts.append("---")
        result = "\n".join(parts)
        _transcript_cache[cache_key] = (result, time.time())
        return result
    except Exception:
        return ""


def load_cooldowns() -> dict[str, str]:
    try:
        f = _get_cooldowns_file()
        return json.loads(f.read_text(encoding="utf-8")) if f.exists() else {}
    except Exception:
        return {}


def save_cooldown(skill: str) -> None:
    try:
        d = _get_data_dir()
        d.mkdir(parents=True, exist_ok=True)
        cooldowns = load_cooldowns()
        cooldowns[skill] = datetime.now(timezone.utc).isoformat()
        _get_cooldowns_file().write_text(json.dumps(cooldowns, indent=2), encoding="utf-8")
    except Exception:
        pass


def is_in_cooldown(skill: str, cooldowns: dict[str, str], cooldown_minutes: int) -> bool:
    last = cooldowns.get(skill)
    if not last:
        return False
    try:
        elapsed = (datetime.now(timezone.utc) - datetime.fromisoformat(last)).total_seconds() / 60
        return elapsed < cooldown_minutes
    except Exception:
        return False


async def recommend_skill(
    context: str,
    bypass_cooldown: bool = False,
    cooldown_minutes: int = 30,
    model: str = DEFAULT_MODEL,
) -> Recommendation | None:
    catalog = load_catalog()
    if not catalog or not context.strip():
        return None
    cooldowns = {} if bypass_cooldown else load_cooldowns()
    skills_text = "\n".join(f"- {s['skill']}: {s['description']}" for s in catalog)
    prompt = (
        f"다음은 Claude Code 대화 히스토리 일부입니다:\n<transcript>\n{context}\n</transcript>\n\n"
        f"다음은 사용 가능한 스킬 목록입니다:\n<skills>\n{skills_text}\n</skills>\n\n"
        "위 맥락을 보고, 지금 작업에 가장 유용한 스킬 1개를 선택하세요.\n"
        '반드시 아래 JSON 형식으로만 응답하세요. 다른 텍스트는 포함하지 마세요.\n'
        '{"skill": "<스킬명>", "reason": "<한 문장 이유>"}'
    )
    raw = await chat_completion(
        messages=[{"role": "user", "content": prompt}],
        model=model,
        max_completion_tokens=100,
        temperature=0.2,
    )
    rec = parse_recommendation(raw, catalog)
    if not rec:
        return None
    if not bypass_cooldown and is_in_cooldown(rec["skill"], cooldowns, cooldown_minutes):
        return None
    return rec
```

- [ ] **Step 4: 테스트 통과 확인**

```bash
tts-venv/bin/pytest tests/test_skill_recommender.py -v
```

Expected: `10 passed`

- [ ] **Step 5: 커밋**

```bash
git add hook_voice/skill_recommender.py tests/test_skill_recommender.py
git commit -m "feat: hook_voice/skill_recommender.py — LLM 스킬 추천 + 쿨다운"
```

---

### Task 8: hook_voice/player.py

**Files:**
- Create: `hook_voice/player.py`
- Create: `tests/test_player.py`

- [ ] **Step 1: 실패하는 테스트 작성**

```python
# tests/test_player.py
import asyncio
import pytest
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock, patch

from hook_voice.player import speak_hook, speak_agent, _enqueue_spool


def test_enqueue_spool_moves_file_and_creates_meta(tmp_path):
    src = tmp_path / "audio.mp3"
    src.write_bytes(b"fake mp3")
    spool = tmp_path / "spool"
    spool.mkdir()

    with patch("hook_voice.player.SPOOL_DIR", spool):
        _enqueue_spool(src, 1.2)

    mp3_files = list(spool.glob("*.mp3"))
    assert len(mp3_files) == 1
    meta = mp3_files[0].with_suffix(".meta")
    assert meta.exists()
    assert meta.read_text() == "1.2"
    assert not src.exists()


async def test_speak_hook_enqueues_via_edge(tmp_path, monkeypatch):
    mp3_src = tmp_path / "edge.mp3"
    mp3_src.write_bytes(b"fake")
    spool = tmp_path / "spool"
    spool.mkdir()

    monkeypatch.setattr("hook_voice.player.SPOOL_DIR", spool)
    monkeypatch.setattr("hook_voice.player._venv_python", lambda: Path("/usr/bin/python3"))
    monkeypatch.setattr("hook_voice.player.save_last_message", lambda t: None)

    async def fake_generate_edge(text):
        mp3_src.write_bytes(b"fake")
        return mp3_src

    with patch("hook_voice.player._generate_edge", side_effect=fake_generate_edge):
        await speak_hook("안녕하세요", "Sohee", 1.2)

    assert len(list(spool.glob("*.mp3"))) == 1


async def test_speak_hook_falls_back_when_edge_fails(tmp_path, monkeypatch):
    spool = tmp_path / "spool"
    spool.mkdir()
    monkeypatch.setattr("hook_voice.player.SPOOL_DIR", spool)
    monkeypatch.setattr("hook_voice.player._venv_python", lambda: Path("/usr/bin/python3"))
    monkeypatch.setattr("hook_voice.player.save_last_message", lambda t: None)

    with patch("hook_voice.player._generate_edge", side_effect=Exception("EdgeTTS 실패")):
        with patch("hook_voice.player._speak_without_edge", new=AsyncMock()) as mock_fallback:
            await speak_hook("안녕", "Sohee", 1.2)
            mock_fallback.assert_called_once()


async def test_speak_agent_enqueues_supertonic(tmp_path, monkeypatch):
    spool = tmp_path / "spool"
    spool.mkdir()
    monkeypatch.setattr("hook_voice.player.SPOOL_DIR", spool)
    monkeypatch.setattr("hook_voice.player.save_last_message", lambda t: None)

    with patch("hook_voice.player._is_supertonic_alive", new=AsyncMock(return_value=True)):
        with patch("hook_voice.player._generate_supertonic", new=AsyncMock(return_value=b"RIFF....WAV")):
            await speak_agent("빌더입니다. 작업 완료", "M4", 7788, 1.2)

    wav_files = list(spool.glob("*.wav"))
    assert len(wav_files) == 1


async def test_speak_agent_skips_empty_text():
    with patch("hook_voice.player._is_supertonic_alive", new=AsyncMock()) as mock:
        await speak_agent("", "M4", 7788, 1.2)
        mock.assert_not_called()
```

- [ ] **Step 2: 테스트 실패 확인**

```bash
tts-venv/bin/pytest tests/test_player.py -v
```

Expected: `ImportError: No module named 'hook_voice.player'`

- [ ] **Step 3: player.py 구현**

```python
# hook_voice/player.py
# EdgeTTS → spool enqueue, speak_hook / speak_agent + HTTP / subprocess 폴백
import asyncio
import os
import random
import ssl
import string
import tempfile
import time
from pathlib import Path

import edge_tts
import edge_tts.communicate as _ec
import httpx

from .last_message import save_last_message

# HMG 사내 SSL 프록시 우회 — edge_tts 내부 SSL 컨텍스트 교체
_ssl_ctx = ssl.create_default_context()
_ssl_ctx.check_hostname = False
_ssl_ctx.verify_mode = ssl.CERT_NONE
_ec._SSL_CTX = _ssl_ctx

SPOOL_DIR = Path("/tmp/tts-spool")
EDGE_VOICE = "ko-KR-HyunsuMultilingualNeural"
TTS_SERVER_URL = "http://localhost:7777"
MLX_MODEL = "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit"
MLX_SPEAKERS = {"Sohee", "Vivian", "Serena", "Uncle_Fu", "Dylan", "Eric", "Ryan", "Aiden", "Ono_Anna"}


def _venv_python() -> Path:
    env = os.environ.get("VOICE_PERSONA_VENV_PYTHON")
    return Path(env) if env else Path(__file__).parent.parent / "tts-venv" / "bin" / "python3"


def _enqueue_spool(audio_file: Path, speed: float) -> None:
    SPOOL_DIR.mkdir(exist_ok=True)
    uid = f"{int(time.time() * 1000)}_{''.join(random.choices(string.ascii_lowercase + string.digits, k=5))}"
    dest = SPOOL_DIR / f"{uid}{audio_file.suffix}"
    audio_file.rename(dest)
    (SPOOL_DIR / f"{uid}.meta").write_text(str(speed))


async def _generate_edge(text: str) -> Path:
    out = Path(tempfile.mktemp(suffix=".mp3", prefix="vp_edge_"))
    comm = edge_tts.Communicate(text, EDGE_VOICE)
    await comm.save(str(out))
    return out


async def _is_tts_server_alive() -> bool:
    try:
        async with httpx.AsyncClient() as client:
            r = await client.get(f"{TTS_SERVER_URL}/health", timeout=0.5)
            return r.is_success
    except Exception:
        return False


async def _speak_http(text: str, voice: str, speed: float) -> None:
    async with httpx.AsyncClient() as client:
        r = await client.post(
            f"{TTS_SERVER_URL}/speak",
            json={"text": text, "voice": voice, "lang_code": "korean", "speed": speed, "instruct": ""},
            timeout=10.0,
        )
        if r.status_code == 429:
            return
        r.raise_for_status()


async def _speak_subprocess(text: str, voice: str, speed: float) -> None:
    py = _venv_python()
    if voice in MLX_SPEAKERS and py.exists():
        proc = await asyncio.create_subprocess_exec(
            str(py), "-m", "mlx_audio.tts.generate",
            "--model", MLX_MODEL,
            "--text", text, "--voice", voice,
            "--lang_code", "korean", "--speed", str(speed),
            "--output_path", "/tmp", "--play",
            env={**os.environ, "HF_HUB_OFFLINE": "1"},
        )
        await proc.wait()
    else:
        proc = await asyncio.create_subprocess_exec("say", text)
        await proc.wait()


async def _speak_without_edge(text: str, voice: str, speed: float) -> None:
    if await _is_tts_server_alive():
        try:
            await _speak_http(text, voice, speed)
            save_last_message(text)
            return
        except Exception:
            pass
    await _speak_subprocess(text, voice, speed)
    save_last_message(text)


async def speak_hook(text: str, voice: str = "Sohee", speed: float = 1.2) -> None:
    skip_edge = os.environ.get("VOICE_PERSONA_OFFLINE") == "1"
    if not skip_edge and _venv_python().exists():
        try:
            mp3 = await asyncio.wait_for(_generate_edge(text), timeout=10.0)
            _enqueue_spool(mp3, speed)
            save_last_message(text)
            return
        except Exception:
            pass
    await _speak_without_edge(text, voice, speed)


async def _is_supertonic_alive(port: int) -> bool:
    try:
        async with httpx.AsyncClient() as client:
            r = await client.get(f"http://localhost:{port}/v1/health", timeout=0.5)
            return r.is_success
    except Exception:
        return False


async def _generate_supertonic(text: str, voice: str, port: int) -> bytes:
    async with httpx.AsyncClient() as client:
        r = await client.post(
            f"http://localhost:{port}/v1/audio/speech",
            json={"model": "supertonic-3", "input": text, "voice": voice,
                  "response_format": "wav", "lang": "ko"},
            timeout=20.0,
        )
        r.raise_for_status()
        return r.content


async def speak_agent(text: str, voice: str, port: int, speed: float) -> None:
    if not text.strip():
        return
    if await _is_supertonic_alive(port):
        try:
            wav_bytes = await asyncio.wait_for(_generate_supertonic(text, voice, port), timeout=20.0)
            tmp = Path(tempfile.mktemp(suffix=".wav", prefix="vp_st_"))
            tmp.write_bytes(wav_bytes)
            _enqueue_spool(tmp, speed)
            save_last_message(text)
            return
        except Exception:
            pass
    await _speak_without_edge(text, voice, speed)
```

- [ ] **Step 4: 테스트 통과 확인**

```bash
tts-venv/bin/pytest tests/test_player.py -v
```

Expected: `5 passed`

- [ ] **Step 5: 커밋**

```bash
git add hook_voice/player.py tests/test_player.py
git commit -m "feat: hook_voice/player.py — EdgeTTS spool + speak_hook/speak_agent"
```

---

### Task 9: hook_voice/hook_handlers.py

**Files:**
- Create: `hook_voice/hook_handlers.py`
- Create: `tests/test_hook_handlers.py`

- [ ] **Step 1: 실패하는 테스트 작성**

```python
# tests/test_hook_handlers.py
import json
import pytest
from pathlib import Path
from unittest.mock import AsyncMock, patch
from hook_voice.config import Config
from hook_voice.hook_handlers import (
    classify_pre_tool_bash,
    classify_post_tool_bash,
    handle_pre_tool_bash,
    handle_post_tool_bash,
    handle_notification,
    handle_hook,
)

_CFG = Config()

# ── 순수 함수 테스트 ──────────────────────────────────────────

def test_classify_pre_destructive():
    assert classify_pre_tool_bash("rm -rf /tmp/foo") == "주의: 되돌릴 수 없는 작업입니다."

def test_classify_pre_build():
    assert classify_pre_tool_bash("npm run build") == "빌드를 시작합니다."

def test_classify_pre_test():
    assert classify_pre_tool_bash("pytest tests/") == "테스트를 실행합니다."

def test_classify_pre_install():
    assert classify_pre_tool_bash("pip install httpx") == "패키지를 설치합니다."

def test_classify_pre_other():
    assert classify_pre_tool_bash("ls -la") is None

def test_classify_post_build_success():
    assert classify_post_tool_bash("npm run build", "", 0) == "빌드 완료."

def test_classify_post_build_failure():
    assert classify_post_tool_bash("tsc", "", 1) == "빌드 실패. 에러를 확인하세요."

def test_classify_post_test_passed():
    result = classify_post_tool_bash("pytest", "5 passed in 1.2s", 0)
    assert result == "전체 5개 통과."

def test_classify_post_test_failed():
    result = classify_post_tool_bash("pytest", "2 failed, 3 passed", 1)
    assert result is not None
    assert "2개 실패" in result
    assert "3개 통과" in result

def test_classify_post_other():
    assert classify_post_tool_bash("ls", "", 0) is None

# ── 비동기 핸들러 테스트 ─────────────────────────────────────

async def test_handle_pre_tool_bash_speaks():
    raw = json.dumps({"tool_input": {"command": "npm run build"}})
    with patch("hook_voice.hook_handlers.speak_hook", new=AsyncMock()) as mock:
        await handle_pre_tool_bash(raw, _CFG)
        mock.assert_called_once()
        assert "빌드" in mock.call_args[0][0]

async def test_handle_pre_tool_bash_silent_for_unknown():
    raw = json.dumps({"tool_input": {"command": "ls -la"}})
    with patch("hook_voice.hook_handlers.speak_hook", new=AsyncMock()) as mock:
        await handle_pre_tool_bash(raw, _CFG)
        mock.assert_not_called()

async def test_handle_post_tool_bash_speaks_on_test_pass():
    raw = json.dumps({
        "tool_input": {"command": "pytest"},
        "tool_response": {"output": "3 passed", "exit_code": 0},
    })
    with patch("hook_voice.hook_handlers.speak_hook", new=AsyncMock()) as mock:
        await handle_post_tool_bash(raw, _CFG)
        mock.assert_called_once()

async def test_handle_notification_speaks():
    raw = json.dumps({"message": "Claude가 응답했습니다"})
    with patch("hook_voice.hook_handlers.speak_hook", new=AsyncMock()) as mock:
        await handle_notification(raw, _CFG)
        mock.assert_called_once_with("Claude가 응답했습니다", _CFG.voice, _CFG.tts_speed)

async def test_handle_notification_uses_title_as_fallback():
    raw = json.dumps({"title": "알림 제목"})
    with patch("hook_voice.hook_handlers.speak_hook", new=AsyncMock()) as mock:
        await handle_notification(raw, _CFG)
        mock.assert_called_once_with("알림 제목", _CFG.voice, _CFG.tts_speed)

async def test_handle_hook_skips_short_text():
    raw = json.dumps({"last_assistant_message": "짧음"})
    with patch("hook_voice.hook_handlers.speak_hook", new=AsyncMock()) as mock:
        await handle_hook(raw, _CFG)
        mock.assert_not_called()
```

- [ ] **Step 2: 테스트 실패 확인**

```bash
tts-venv/bin/pytest tests/test_hook_handlers.py -v
```

Expected: `ImportError: No module named 'hook_voice.hook_handlers'`

- [ ] **Step 3: hook_handlers.py 구현**

```python
# hook_voice/hook_handlers.py
# 각 hook subcommand 구현 함수
import json
import os
import re
from pathlib import Path

from .config import Config
from .player import speak_hook, speak_agent
from .summarizer import extract_summary, extract_one_liner
from .voice_router import load_voice_map, resolve_voice, get_agent_label
from .skill_recommender import read_recent_transcripts, recommend_skill, save_cooldown


def _derive_transcript_path() -> Path | None:
    session_id = os.environ.get("CLAUDE_CODE_SESSION_ID", "")
    project_dir = os.environ.get("CLAUDE_PROJECT_DIR", "")
    home = os.environ.get("HOME", "")
    if not session_id or not project_dir or not home:
        return None
    slug = project_dir.replace("/", "-")
    return Path(home) / ".claude" / "projects" / slug / f"{session_id}.jsonl"


def _extract_last_assistant_text(transcript_path: Path) -> str:
    if not transcript_path.exists():
        return ""
    try:
        for line in reversed(transcript_path.read_text(encoding="utf-8").splitlines()):
            try:
                entry = json.loads(line)
                msg = entry.get("message", entry)
                if msg.get("role") != "assistant":
                    continue
                content = msg.get("content", [])
                if isinstance(content, list):
                    for block in content:
                        if isinstance(block, dict) and block.get("type") == "text":
                            text = block.get("text", "")
                            if len(text) >= 20:
                                return text
                elif isinstance(content, str) and len(content) >= 20:
                    return content
            except Exception:
                pass
    except Exception:
        pass
    return ""


def _extract_agent_type_from_transcript(path: Path) -> str:
    if not path.exists():
        return ""
    try:
        for line in reversed(path.read_text(encoding="utf-8").splitlines()):
            try:
                entry = json.loads(line)
                for block in entry.get("content", []):
                    if (
                        isinstance(block, dict)
                        and block.get("type") == "tool_use"
                        and block.get("name") == "Agent"
                    ):
                        t = block.get("input", {}).get("subagent_type", "")
                        if t:
                            return t
            except Exception:
                pass
    except Exception:
        pass
    return ""


def classify_pre_tool_bash(cmd: str) -> str | None:
    if re.search(r"rm\s+-rf|git\s+reset\s+--hard|DROP\s+TABLE", cmd):
        return "주의: 되돌릴 수 없는 작업입니다."
    if re.search(r"npm run build|tsc\b|cargo build|go build", cmd):
        return "빌드를 시작합니다."
    if re.search(r"npm\s+test|vitest|pytest|cargo\s+test|go\s+test", cmd):
        return "테스트를 실행합니다."
    if re.search(r"npm\s+install|npm\s+ci|pip\s+install|uv\s+sync", cmd):
        return "패키지를 설치합니다."
    return None


def classify_post_tool_bash(cmd: str, output: str, exit_code: int) -> str | None:
    if re.search(r"npm run build|tsc\b|cargo build|go build", cmd):
        return "빌드 완료." if exit_code == 0 else "빌드 실패. 에러를 확인하세요."
    if re.search(r"npm\s+test|vitest|pytest|cargo\s+test|go\s+test", cmd):
        passed = re.search(r"(\d+)\s*(passed|passing)", output)
        failed = re.search(r"(\d+)\s*(failed|failing)", output)
        if failed and int(failed.group(1)) > 0:
            p = f", {passed.group(1)}개 통과" if passed else ""
            return f"테스트 {failed.group(1)}개 실패{p}."
        if passed:
            return f"전체 {passed.group(1)}개 통과."
    return None


async def handle_hook(raw: str, config: Config) -> None:
    text = ""
    try:
        data = json.loads(raw)
        text = data.get("last_assistant_message", "")
    except Exception:
        pass
    if not text:
        tp = _derive_transcript_path()
        if tp:
            text = _extract_last_assistant_text(tp)
    if config.auto_speak and len(text) >= config.min_chars:
        summary = await extract_summary(text, config.summary_model)
        await speak_hook(summary, config.voice, config.tts_speed)


async def handle_notification(raw: str, config: Config) -> None:
    try:
        data = json.loads(raw)
        msg = data.get("message") or data.get("title") or ""
    except Exception:
        msg = ""
    if msg and config.auto_speak:
        await speak_hook(msg, config.voice, config.tts_speed)


async def handle_subagent_stop(raw: str, agent_type: str, config: Config) -> None:
    text = raw
    try:
        data = json.loads(raw)
        text = data.get("last_assistant_message", raw)
        if not agent_type:
            tp = data.get("transcript_path", "")
            if tp:
                agent_type = _extract_agent_type_from_transcript(Path(tp))
    except Exception:
        pass
    if len(text) < config.min_chars:
        return
    vm = load_voice_map()
    voice = resolve_voice(agent_type, vm)
    label = get_agent_label(agent_type, vm)
    one_liner = await extract_one_liner(text, config.summary_model)
    await speak_agent(f"{label}입니다. {one_liner}", voice, config.supertonic_port, config.tts_speed)


async def handle_hook_suggest(raw: str, config: Config) -> None:
    prompt_hint = ""
    try:
        data = json.loads(raw)
        prompt = data.get("prompt", "")
        if len(prompt) >= 10:
            prompt_hint = f"\n[현재 입력]: {prompt[:200]}"
    except Exception:
        pass
    context = read_recent_transcripts() + prompt_hint
    rec = await recommend_skill(
        context,
        bypass_cooldown=False,
        cooldown_minutes=config.skill_cooldown_minutes,
        model=config.summary_model,
    )
    if rec:
        await speak_hook(f"지금 상황엔 {rec['skill']} 스킬이 유용할 것 같아요", config.voice, config.tts_speed)
        save_cooldown(rec["skill"])


async def handle_pre_tool_bash(raw: str, config: Config) -> None:
    if not config.auto_speak:
        return
    try:
        data = json.loads(raw)
        cmd = data.get("tool_input", {}).get("command", "")
    except Exception:
        return
    msg = classify_pre_tool_bash(cmd)
    if msg:
        await speak_hook(msg, config.voice, config.tts_speed)


async def handle_post_tool_bash(raw: str, config: Config) -> None:
    if not config.auto_speak:
        return
    try:
        data = json.loads(raw)
        cmd = data.get("tool_input", {}).get("command", "")
        resp = data.get("tool_response", {})
        out = resp.get("output", "")
        code = resp.get("exitCode", resp.get("exit_code", 0))
    except Exception:
        return
    msg = classify_post_tool_bash(cmd, out, code)
    if msg:
        await speak_hook(msg, config.voice, config.tts_speed)
```

- [ ] **Step 4: 테스트 통과 확인**

```bash
tts-venv/bin/pytest tests/test_hook_handlers.py -v
```

Expected: `16 passed`

- [ ] **Step 5: 커밋**

```bash
git add hook_voice/hook_handlers.py tests/test_hook_handlers.py
git commit -m "feat: hook_voice/hook_handlers.py — 모든 hook subcommand 구현"
```

---

### Task 10: hook_voice/__main__.py

**Files:**
- Create: `hook_voice/__main__.py`
- Create: `tests/test_main.py`

- [ ] **Step 1: 실패하는 테스트 작성**

```python
# tests/test_main.py
import json
import sys
import pytest
from unittest.mock import AsyncMock, patch


async def _run_main(argv, stdin_data=""):
    with patch("sys.argv", argv):
        with patch("hook_voice.__main__._read_stdin", new=AsyncMock(return_value=stdin_data)):
            from hook_voice.__main__ import main
            await main()


async def test_hook_subcommand_dispatches():
    with patch("hook_voice.__main__.handle_hook", new=AsyncMock()) as mock:
        await _run_main(["prog", "hook"], json.dumps({"last_assistant_message": ""}))
        mock.assert_called_once()


async def test_notification_subcommand_dispatches():
    with patch("hook_voice.__main__.handle_notification", new=AsyncMock()) as mock:
        await _run_main(["prog", "notification"], json.dumps({"message": "알림"}))
        mock.assert_called_once()


async def test_pre_tool_bash_subcommand_dispatches():
    with patch("hook_voice.__main__.handle_pre_tool_bash", new=AsyncMock()) as mock:
        await _run_main(["prog", "pre-tool-bash"], "{}")
        mock.assert_called_once()


async def test_post_tool_bash_subcommand_dispatches():
    with patch("hook_voice.__main__.handle_post_tool_bash", new=AsyncMock()) as mock:
        await _run_main(["prog", "post-tool-bash"], "{}")
        mock.assert_called_once()


async def test_hook_suggest_subcommand_dispatches():
    with patch("hook_voice.__main__.handle_hook_suggest", new=AsyncMock()) as mock:
        await _run_main(["prog", "hook-suggest"], "{}")
        mock.assert_called_once()


async def test_unknown_subcommand_exits_1():
    with pytest.raises(SystemExit) as exc:
        await _run_main(["prog", "unknown-cmd"])
    assert exc.value.code == 1
```

- [ ] **Step 2: 테스트 실패 확인**

```bash
tts-venv/bin/pytest tests/test_main.py -v
```

Expected: `ImportError: No module named 'hook_voice.__main__'`

- [ ] **Step 3: __main__.py 구현**

```python
# hook_voice/__main__.py
# python -m hook_voice <subcommand> 진입점
import asyncio
import sys


async def _read_stdin() -> str:
    if sys.stdin.isatty():
        return ""
    loop = asyncio.get_event_loop()
    data = await loop.run_in_executor(None, sys.stdin.buffer.read)
    return data.decode("utf-8").strip()


async def main() -> None:
    from .config import load_config
    from .hook_handlers import (
        handle_hook,
        handle_notification,
        handle_subagent_stop,
        handle_hook_suggest,
        handle_pre_tool_bash,
        handle_post_tool_bash,
    )

    if len(sys.argv) < 2:
        print("Usage: python -m hook_voice <subcommand>", file=sys.stderr)
        sys.exit(1)

    subcommand = sys.argv[1]
    config = load_config()
    raw = await _read_stdin()

    if subcommand == "hook":
        await handle_hook(raw, config)
    elif subcommand == "notification":
        await handle_notification(raw, config)
    elif subcommand == "subagent-stop":
        agent_type = sys.argv[2] if len(sys.argv) > 2 else ""
        await handle_subagent_stop(raw, agent_type, config)
    elif subcommand == "hook-suggest":
        await handle_hook_suggest(raw, config)
    elif subcommand == "pre-tool-bash":
        await handle_pre_tool_bash(raw, config)
    elif subcommand == "post-tool-bash":
        await handle_post_tool_bash(raw, config)
    else:
        print(f"Unknown subcommand: {subcommand}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main())
```

- [ ] **Step 4: 전체 테스트 통과 확인**

```bash
tts-venv/bin/pytest tests/ -v
```

Expected: 모든 tests/ 테스트 통과

- [ ] **Step 5: 커밋**

```bash
git add hook_voice/__main__.py tests/test_main.py
git commit -m "feat: hook_voice/__main__.py — python -m hook_voice CLI 진입점"
```

---

### Task 11: shell scripts 업데이트

**Files:**
- Modify: `hooks/stop.sh`
- Modify: `hooks/notification.sh`
- Modify: `hooks/prompt-submit.sh`
- Modify: `hooks/session-start.sh`
- Modify: `hooks/pre-tool-bash.sh`
- Modify: `hooks/post-tool-bash.sh`
- Modify: `hooks/subagent-stop.sh`

- [ ] **Step 1: 각 hook 스크립트를 python으로 교체**

`hooks/stop.sh`:
```bash
#!/usr/bin/env bash
# Claude Code Stop hook — 응답 완료 시 자동 TTS 실행
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_PY="$SCRIPT_DIR/../tts-venv/bin/python"
nohup "$VENV_PY" -m hook_voice hook >> /tmp/voice-notification-debug.log 2>&1 &
disown $!; exit 0
```

`hooks/notification.sh`:
```bash
#!/usr/bin/env bash
# Notification hook — Claude 알림 메시지를 voice로 낭독
PAYLOAD=$(cat)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_PY="$SCRIPT_DIR/../tts-venv/bin/python"
echo "$(date '+%H:%M:%S') [notification] $PAYLOAD" >> /tmp/voice-notification-debug.log
echo "$PAYLOAD" | nohup "$VENV_PY" -m hook_voice notification >> /tmp/voice-notification-debug.log 2>&1 &
disown $!; exit 0
```

`hooks/prompt-submit.sh`:
```bash
#!/usr/bin/env bash
# Claude Code UserPromptSubmit hook — 프롬프트 입력 시 스킬 추천
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_PY="$SCRIPT_DIR/../tts-venv/bin/python"
nohup "$VENV_PY" -m hook_voice hook-suggest > /dev/null 2>&1 &
disown $!; exit 0
```

`hooks/session-start.sh`:
```bash
#!/usr/bin/env bash
# Claude Code SessionStart hook — 세션 시작 시 스킬 추천
cat > /dev/null
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_PY="$SCRIPT_DIR/../tts-venv/bin/python"
nohup "$VENV_PY" -m hook_voice hook-suggest > /dev/null 2>&1 &
disown $!; exit 0
```

`hooks/pre-tool-bash.sh`:
```bash
#!/usr/bin/env bash
# PreToolUse Bash hook — 빌드·테스트 착수 및 파괴적 명령 경고를 voice로 알림
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_PY="$SCRIPT_DIR/../tts-venv/bin/python"
nohup "$VENV_PY" -m hook_voice pre-tool-bash > /dev/null 2>&1 &
disown $!; exit 0
```

`hooks/post-tool-bash.sh`:
```bash
#!/usr/bin/env bash
# PostToolUse Bash hook — 빌드·테스트 결과를 voice로 알림
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_PY="$SCRIPT_DIR/../tts-venv/bin/python"
nohup "$VENV_PY" -m hook_voice post-tool-bash > /dev/null 2>&1 &
disown $!; exit 0
```

`hooks/subagent-stop.sh`:
```bash
#!/usr/bin/env bash
# Claude Code SubagentStop hook — 서브에이전트 응답 완료 시 에이전트별 TTS 실행
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_PY="$SCRIPT_DIR/../tts-venv/bin/python"
nohup "$VENV_PY" -m hook_voice subagent-stop > /dev/null 2>&1 &
disown $!; exit 0
```

- [ ] **Step 2: 실행 권한 확인**

```bash
ls -la hooks/*.sh
```

Expected: 모든 파일에 `x` 권한 있음 (없으면 `chmod +x hooks/*.sh`)

- [ ] **Step 3: 동작 확인 (건식 테스트)**

```bash
echo '{"last_assistant_message": "이것은 50자 이상의 테스트 메시지입니다. 충분히 긴 텍스트여야 합니다."}' \
  | tts-venv/bin/python -m hook_voice hook
echo "exit: $?"
```

Expected: `exit: 0` (TTS는 백그라운드로 스풀에 enqueue됨)

- [ ] **Step 4: 커밋**

```bash
git add hooks/
git commit -m "feat: hooks/*.sh — node → python -m hook_voice 전환"
```

---

### Task 12: TypeScript 파일 삭제 및 server.sh 정리

**Files:**
- Delete: `src/` (전체)
- Delete: `tests/*.test.ts` (전체)
- Delete: `vitest.config.ts`
- Delete: `package.json`, `package-lock.json`, `tsconfig.json`
- Modify: `server.sh` (npm build 단계 제거)

- [ ] **Step 1: TypeScript 소스 삭제**

```bash
rm -rf src/
rm -f vitest.config.ts
rm -f package.json package-lock.json tsconfig.json
```

- [ ] **Step 2: vitest 테스트 파일 삭제**

```bash
rm -f tests/*.test.ts tests/*.test.js 2>/dev/null || true
```

- [ ] **Step 3: server.sh에서 npm build 단계 제거**

`server.sh`에서 `npm run build` 관련 코드를 찾아 제거한다.

```bash
grep -n "npm" server.sh
```

npm 관련 줄(예: `npm run build`, `npm install` 등)을 삭제한다. `do_restart()` 함수나 `do_status()` 함수에 포함된 npm 빌드 상태 체크 코드도 제거한다.

- [ ] **Step 4: 전체 Python 테스트 통과 확인**

```bash
tts-venv/bin/pytest tests/ tts_server/test_server.py tts_server/test_supervisor.py -v
```

Expected: 모든 테스트 통과

- [ ] **Step 5: node_modules / dist 정리 (gitignore됨)**

```bash
rm -rf node_modules/ dist/ 2>/dev/null || true
```

- [ ] **Step 6: 최종 커밋**

```bash
git add -A
git commit -m "chore: TypeScript 파일 전면 삭제 — Python hook_voice 단일 스택으로 전환"
```
