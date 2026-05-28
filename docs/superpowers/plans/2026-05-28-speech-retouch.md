# Speech Retouch 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** LLM 리터치 단계를 추가해 `**별표**`, `API` 같은 마크다운·영문 IT 용어가 TTS에서 이상하게 발화되는 문제를 해결한다.

**Architecture:** `summarizer.py`에 `retouch_for_speech` async 함수를 추가하고, `handle_hook` / `handle_subagent_stop`에서 요약 후 명시적으로 호출한다. `player.py`는 LLM 의존성 없이 순수 오디오 모듈로 유지한다.

**Tech Stack:** Python 3.11+, pytest-asyncio, unittest.mock.AsyncMock, HMG Hub LLM API (chat_completion)

---

## 파일 목록

| 파일 | 역할 |
|------|------|
| `hook_voice/config.py` | `speech_retouch: bool` 설정 추가 |
| `hook_voice/summarizer.py` | `retouch_for_speech` 추가, `extract_summary` 버그 수정 |
| `hook_voice/hook_handlers.py` | `handle_hook` / `handle_subagent_stop`에 retouch 호출 |
| `tests/test_summarizer.py` | retouch + extract_summary 버그 수정 테스트 |
| `tests/test_hook_handlers.py` | handle_hook / handle_subagent_stop retouch 분기 테스트 |

---

## Task 1: `config.py` — `speech_retouch` 설정 추가

**Files:**
- Modify: `hook_voice/config.py`
- Test: `tests/test_config.py`

- [ ] **Step 1: 테스트 작성**

`tests/test_config.py` 파일 끝에 추가:

```python
def test_load_config_speech_retouch_default():
    """speech_retouch 기본값은 True."""
    cfg = load_config(None)
    assert cfg.speech_retouch is True


def test_load_config_speech_retouch_from_file(tmp_path):
    """speechRetouch=false 설정 파일에서 올바르게 로드."""
    f = tmp_path / ".voice.json"
    f.write_text('{"speechRetouch": false}', encoding="utf-8")
    cfg = load_config(f)
    assert cfg.speech_retouch is False
```

- [ ] **Step 2: 테스트 실패 확인**

```bash
.venv/bin/pytest tests/test_config.py::test_load_config_speech_retouch_default tests/test_config.py::test_load_config_speech_retouch_from_file -v
```

Expected: `AttributeError: 'Config' object has no attribute 'speech_retouch'`

- [ ] **Step 3: `config.py` 수정 — `_KEY_MAP`에 키 추가**

`hook_voice/config.py` 의 `_KEY_MAP` dict에 마지막 항목 뒤에 추가:

```python
    "allowInsecureTls": "allow_insecure_tls",
    "speechRetouch": "speech_retouch",   # ← 추가
```

- [ ] **Step 4: `Config` dataclass에 필드 추가**

`allow_insecure_tls: bool = True` 줄 바로 뒤에 추가:

```python
    allow_insecure_tls: bool = True
    speech_retouch: bool = True   # ← 추가
```

- [ ] **Step 5: `_normalize_config`에 bool 검증 추가**

`_normalize_bool("allow_insecure_tls")` 줄 바로 뒤에 추가:

```python
    _normalize_bool("allow_insecure_tls")
    _normalize_bool("speech_retouch")   # ← 추가
```

- [ ] **Step 6: 테스트 통과 확인**

```bash
.venv/bin/pytest tests/test_config.py -v
```

Expected: 전체 PASS

- [ ] **Step 7: 커밋**

```bash
git add hook_voice/config.py tests/test_config.py
git commit -m "feat: speech_retouch 설정 키 추가"
```

---

## Task 2: `summarizer.py` — `extract_summary` 버그 수정

**Files:**
- Modify: `hook_voice/summarizer.py:105-117`
- Test: `tests/test_summarizer.py`

LLM이 `**굵게**` 같은 마크다운을 반환할 경우 그대로 EdgeTTS로 전달되는 버그. `sanitize_for_speech`를 반환 전에 적용한다.

- [ ] **Step 1: 테스트 작성**

`tests/test_summarizer.py` 파일 끝에 추가:

```python
async def test_extract_summary_sanitizes_markdown_in_llm_result():
    """LLM이 마크다운을 반환해도 sanitize 후 반환된다."""
    with patch("hook_voice.summarizer.chat_completion", new=AsyncMock(return_value="결과는 **중요함**")):
        result = await extract_summary("텍스트")
        assert "**" not in result
        assert "중요함" in result


async def test_extract_summary_sanitizes_fallback():
    """LLM 결과가 없을 때 fallback도 sanitize된다."""
    with patch("hook_voice.summarizer.chat_completion", new=AsyncMock(return_value="")):
        result = await extract_summary("첫 문장. 두 번째!? 마지막.")
        assert result  # 비어 있지 않음
```

- [ ] **Step 2: 테스트 실패 확인**

```bash
.venv/bin/pytest tests/test_summarizer.py::test_extract_summary_sanitizes_markdown_in_llm_result -v
```

Expected: FAIL (`**` 가 result에 포함됨)

- [ ] **Step 3: `extract_summary` 반환값에 `sanitize_for_speech` 적용**

`hook_voice/summarizer.py` 의 `extract_summary` 함수 마지막 줄:

```python
# 변경 전
    return result or _fallback(text)

# 변경 후
    return sanitize_for_speech(result or _fallback(text))
```

- [ ] **Step 4: 테스트 통과 확인**

```bash
.venv/bin/pytest tests/test_summarizer.py -v
```

Expected: 전체 PASS (기존 테스트도 모두 통과 — `sanitize_for_speech("LLM 요약")` == `"LLM 요약"`)

- [ ] **Step 5: 커밋**

```bash
git add hook_voice/summarizer.py tests/test_summarizer.py
git commit -m "fix: extract_summary 반환값에 sanitize_for_speech 적용"
```

---

## Task 3: `summarizer.py` — `retouch_for_speech` 추가

**Files:**
- Modify: `hook_voice/summarizer.py`
- Test: `tests/test_summarizer.py`

- [ ] **Step 1: 테스트 작성**

`tests/test_summarizer.py` import 줄에 `retouch_for_speech` 추가:

```python
from hook_voice.summarizer import (
    strip_markdown, sanitize_for_speech,
    extract_summary, extract_one_liner,
    select_expression_tag, retouch_for_speech,  # ← 추가
)
```

그리고 파일 끝에 테스트 추가:

```python
async def test_retouch_removes_markdown():
    """LLM이 마크다운 제거 결과를 반환하면 그대로 전달."""
    with patch("hook_voice.summarizer.chat_completion", new=AsyncMock(return_value="굵은글씨")):
        result = await retouch_for_speech("**굵은글씨**")
        assert result == "굵은글씨"


async def test_retouch_converts_it_terms():
    """LLM이 IT 용어를 한국어 발음으로 변환한 결과를 반환."""
    with patch("hook_voice.summarizer.chat_completion", new=AsyncMock(return_value="에이피아이 호출 완료")):
        result = await retouch_for_speech("API 호출 완료")
        assert "에이피아이" in result


async def test_retouch_preserves_expression_tags():
    """Expression Tag는 sanitize 후에도 보존된다."""
    with patch("hook_voice.summarizer.chat_completion", new=AsyncMock(return_value="<breath> 안녕하세요")):
        result = await retouch_for_speech("<breath> 안녕하세요")
        assert "<breath>" in result
        assert "안녕하세요" in result


async def test_retouch_fallback_on_llm_failure():
    """LLM 예외 시 sanitize_for_speech 결과를 반환한다."""
    with patch("hook_voice.summarizer.chat_completion", new=AsyncMock(side_effect=Exception("network error"))):
        result = await retouch_for_speech("**굵은글씨** 텍스트")
        assert "**" not in result
        assert "텍스트" in result


async def test_retouch_returns_blank_for_blank_input():
    """빈 문자열 입력은 LLM 호출 없이 그대로 반환."""
    with patch("hook_voice.summarizer.chat_completion", new=AsyncMock()) as mock_llm:
        result = await retouch_for_speech("   ")
        mock_llm.assert_not_called()
        assert result.strip() == ""
```

- [ ] **Step 2: 테스트 실패 확인**

```bash
.venv/bin/pytest tests/test_summarizer.py::test_retouch_removes_markdown -v
```

Expected: `ImportError: cannot import name 'retouch_for_speech'`

- [ ] **Step 3: `_RETOUCH_SYSTEM` 상수 추가**

`hook_voice/summarizer.py` 의 `_ONE_LINER_SYSTEM` 상수 바로 뒤에 추가:

```python
_RETOUCH_SYSTEM = (
    "다음 텍스트를 한국어 TTS 발화에 적합하게 정제하세요.\n"
    "1. 마크다운 기호(** * # ` [] | > —) 완전 제거\n"
    "2. 영문 IT 용어를 한국어 발음으로 변환 (API→에이피아이, GPU→지피유, HTTP→에이치티티피, LLM→엘엘엠)\n"
    "3. 코드 블록·URL은 '[코드 생략]' / '[링크 생략]'으로\n"
    "4. 특수 기호(→ ← ≥ ± © ® ™ …) 제거 또는 한국어로\n"
    "5. <breath> <laugh> <sigh> <clear_throat> <hmm> <cough> <sniff> <gasp> <yawn> <cry> 태그는 그대로 보존\n"
    "6. 의미 변경 없이 정제만 — 새 내용 추가 금지\n"
    "출력: 정제된 텍스트만, 설명 없이"
)
```

- [ ] **Step 4: `retouch_for_speech` 함수 추가**

`extract_summary` 함수 바로 앞에 추가:

```python
async def retouch_for_speech(text: str, model: str = DEFAULT_MODEL) -> str:
    """LLM으로 TTS 발화용 텍스트 정제 — 마크다운 제거, IT 용어 발음 변환."""
    if not text.strip():
        return text
    try:
        result = await chat_completion(
            messages=[
                {"role": "system", "content": _RETOUCH_SYSTEM},
                {"role": "user", "content": text},
            ],
            model=model,
            max_completion_tokens=300,
            temperature=0.0,
        )
        return sanitize_for_speech(result) if result else sanitize_for_speech(text)
    except Exception:
        return sanitize_for_speech(text)
```

- [ ] **Step 5: 테스트 통과 확인**

```bash
.venv/bin/pytest tests/test_summarizer.py -v
```

Expected: 전체 PASS

- [ ] **Step 6: 커밋**

```bash
git add hook_voice/summarizer.py tests/test_summarizer.py
git commit -m "feat: retouch_for_speech — LLM 기반 TTS 텍스트 정제 함수 추가"
```

---

## Task 4: `hook_handlers.py` — retouch 호출 추가

**Files:**
- Modify: `hook_voice/hook_handlers.py`
- Test: `tests/test_hook_handlers.py`

Task 3 완료 후 진행.

- [ ] **Step 1: 테스트 작성**

`tests/test_hook_handlers.py` 파일에 다음 테스트 추가 (파일 끝에):

```python
async def test_handle_hook_calls_retouch_when_enabled():
    """speech_retouch=True이면 retouch_for_speech가 호출된다."""
    from hook_voice.config import Config
    from hook_voice.hook_handlers import handle_hook
    config = Config(auto_speak=True, min_chars=5, speech_retouch=True)
    with patch("hook_voice.hook_handlers.extract_summary", new=AsyncMock(return_value="요약")) as _mock_sum, \
         patch("hook_voice.hook_handlers.retouch_for_speech", new=AsyncMock(return_value="정제됨")) as mock_retouch, \
         patch("hook_voice.hook_handlers.speak_hook", new=AsyncMock()) as mock_speak:
        await handle_hook('{"last_assistant_message": "충분히 긴 텍스트입니다"}', config)
        mock_retouch.assert_called_once_with("요약", config.summary_model)
        mock_speak.assert_called_once()
        assert mock_speak.call_args[0][0] == "정제됨"


async def test_handle_hook_skips_retouch_when_disabled():
    """speech_retouch=False이면 retouch_for_speech가 호출되지 않는다."""
    from hook_voice.config import Config
    from hook_voice.hook_handlers import handle_hook
    config = Config(auto_speak=True, min_chars=5, speech_retouch=False)
    with patch("hook_voice.hook_handlers.extract_summary", new=AsyncMock(return_value="요약")), \
         patch("hook_voice.hook_handlers.retouch_for_speech", new=AsyncMock()) as mock_retouch, \
         patch("hook_voice.hook_handlers.speak_hook", new=AsyncMock()) as mock_speak:
        await handle_hook('{"last_assistant_message": "충분히 긴 텍스트입니다"}', config)
        mock_retouch.assert_not_called()
        assert mock_speak.call_args[0][0] == "요약"


async def test_handle_subagent_stop_calls_retouch_when_enabled():
    """handle_subagent_stop에서 speech_retouch=True이면 retouch가 호출된다."""
    from hook_voice.config import Config
    from hook_voice.hook_handlers import handle_subagent_stop
    config = Config(auto_speak=True, min_chars=5, speech_retouch=True)
    vm = {"voices": {}, "supertonic": {"steps": 12}}
    with patch("hook_voice.hook_handlers.load_voice_map", return_value=vm), \
         patch("hook_voice.hook_handlers.resolve_voice", return_value="F1"), \
         patch("hook_voice.hook_handlers.resolve_voice_name", return_value="연아"), \
         patch("hook_voice.hook_handlers.get_agent_label", return_value="기본"), \
         patch("hook_voice.hook_handlers.resolve_instruct", return_value=""), \
         patch("hook_voice.hook_handlers.resolve_category", return_value="default"), \
         patch("hook_voice.hook_handlers.extract_one_liner", new=AsyncMock(return_value="작업 완료")), \
         patch("hook_voice.hook_handlers.retouch_for_speech", new=AsyncMock(return_value="작업 완료")) as mock_retouch, \
         patch("hook_voice.hook_handlers.speak_agent", new=AsyncMock()):
        await handle_subagent_stop('{"last_assistant_message": "충분히 긴 내용입니다"}', "default", config)
        mock_retouch.assert_called_once_with("작업 완료", config.summary_model)
```

- [ ] **Step 2: 테스트 실패 확인**

```bash
.venv/bin/pytest tests/test_hook_handlers.py::test_handle_hook_calls_retouch_when_enabled -v
```

Expected: FAIL (`retouch_for_speech` not imported in hook_handlers)

- [ ] **Step 3: import 추가**

`hook_voice/hook_handlers.py` 의 import 줄 수정:

```python
# 변경 전
from .summarizer import extract_summary, extract_one_liner, select_expression_tag

# 변경 후
from .summarizer import extract_summary, extract_one_liner, select_expression_tag, retouch_for_speech
```

- [ ] **Step 4: `handle_hook` 수정**

`handle_hook` 함수에서 `speak_hook` 호출 직전에 retouch 분기 추가:

```python
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
            text = get_last_assistant_text(tp)
    if config.auto_speak and len(text) >= config.min_chars:
        summary = await extract_summary(text, config.summary_model)
        if config.speech_retouch:
            summary = await retouch_for_speech(summary, config.summary_model)
        await speak_hook(summary, config.voice, config.tts_speed,
                         edge_timeout=config.edge_timeout_ms / 1000)
```

- [ ] **Step 5: `handle_subagent_stop` 수정**

`one_liner = await extract_one_liner(...)` 줄 바로 뒤에 분기 추가:

```python
    one_liner = await extract_one_liner(text, config.summary_model)
    if config.speech_retouch:
        one_liner = await retouch_for_speech(one_liner, config.summary_model)
    tag = select_expression_tag(one_liner, category)
```

- [ ] **Step 6: 테스트 통과 확인**

```bash
.venv/bin/pytest tests/test_hook_handlers.py -v
```

Expected: 전체 PASS

- [ ] **Step 7: 전체 테스트 통과 확인**

```bash
.venv/bin/pytest tests/ tts_server/test_server.py tts_server/test_supervisor.py -v
```

Expected: 전체 PASS

- [ ] **Step 8: 커밋**

```bash
git add hook_voice/hook_handlers.py tests/test_hook_handlers.py
git commit -m "feat: handle_hook / handle_subagent_stop에 speech_retouch 단계 추가"
```

---

## 완료 기준

- [ ] `**별표**` 포함 텍스트가 EdgeTTS로 전달되지 않음
- [ ] `API`, `GPU`, `HTTP` 등 IT 용어가 한국어 발음으로 변환됨
- [ ] `<breath>` 등 Expression Tag가 보존됨
- [ ] `speechRetouch: false`로 비활성화 가능
- [ ] 전체 테스트 PASS
