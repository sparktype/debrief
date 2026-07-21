# TypeScript → Python 전환 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** TypeScript/Node.js 기반 hook CLI를 Python으로 전환하여 단일 Python 스택으로 단순화한다.

**Architecture:** `hook_voice` Python 패키지를 새로 생성하고, 기존 `src/*.ts`의 모든 로직을 asyncio 기반 Python으로 재구현한다. MCP 서버 기능은 제거하고 hook CLI만 유지한다. 기존 `tts_server/` 패키지는 변경 없이 유지한다.

**Tech Stack:** Python 3.11+, asyncio, edge_tts, httpx, pytest, pytest-asyncio

---

## 현재 구조

```
src/                     # TypeScript (제거 대상)
  config.ts
  hook-handlers.ts
  index.ts
  last-message-store.ts
  llm-client.ts
  player.ts
  skill-recommender.ts
  summarizer.ts
  voice-router.ts
tests/                   # vitest 테스트 (제거 대상)
  *.test.ts
tts_server/              # Python (유지)
  server.py
  supervisor.py
  test_server.py
  test_supervisor.py
```

## 목표 구조

```
hook_voice/
  __init__.py
  __main__.py            # python -m hook_voice <subcommand> 진입점
  config.py              # .voice-persona.json 로더, 기본값 관리
  player.py              # EdgeTTS → spool, speak_hook / speak_agent
  summarizer.py          # LLM 요약 (extract_summary, extract_one_liner)
  llm_client.py          # HMG Hub API (httpx AsyncClient)
  voice_router.py        # agentType → voice ID (voice-map.json)
  skill_recommender.py   # transcript 분석 → 스킬 추천 + 쿨다운
  last_message.py        # 마지막 TTS 텍스트 파일 영속화
  hook_handlers.py       # 각 subcommand 구현 함수
tests/
  test_config.py
  test_player.py
  test_summarizer.py
  test_hook_handlers.py
  test_voice_router.py
  test_skill_recommender.py
```

## 데이터 흐름

### `python -m hook_voice hook` (Stop hook)
```
stdin JSON { last_assistant_message? }
  → 없으면 transcript.jsonl 에서 마지막 assistant 텍스트 추출
  → extract_summary(text) via LLM
  → speak_hook(summary) → edge_tts 생성 → /tmp/tts-spool/ enqueue
```

### `python -m hook_voice notification` (Notification hook)
```
stdin JSON { message?, title? }
  → msg = message ?? title
  → speak_hook(msg)
```

### `python -m hook_voice subagent-stop [agentType]` (SubagentStop hook)
```
stdin JSON + argv agentType
  → resolve_voice(agentType) via voice-map.json
  → extract_one_liner(text) via LLM (25자 이내)
  → speak_agent(f"{label}입니다. {one_liner}", voice)
```

### `python -m hook_voice hook-suggest` (UserPromptSubmit hook)
```
stdin JSON { prompt? }
  → read_recent_transcripts() + prompt
  → recommend_skill(context, cooldown_minutes) via LLM
  → 추천 있으면 speak_hook(f"지금 상황엔 {skill} 스킬이 유용할 것 같아요")
```

### `python -m hook_voice pre-tool-bash` / `post-tool-bash`
```
stdin JSON { tool_input.command, tool_response.output, exitCode }
  → classify_pre_tool_bash(cmd) or classify_post_tool_bash(cmd, output, exit_code)
  → msg 있으면 speak_hook(msg)
```

### `speak_hook()` 내부
```python
async def speak_hook(text: str, voice: str, speed: float) -> None:
    try:
        mp3 = await _generate_edge(text)    # edge_tts.Communicate 직접 사용
        _enqueue_spool(mp3, speed)           # rename to /tmp/tts-spool/<ts>_<rand>.mp3
    except Exception:
        await _speak_without_edge(text, voice, speed)  # HTTP(7777) → subprocess 폴백
```

## 의존성

| 패키지 | 용도 | 상태 |
|--------|------|------|
| `edge_tts` | EdgeTTS MP3 생성 (async) | tts-venv 기설치 |
| `httpx` | LLM API + TTS 서버 HTTP 호출 | **신규 추가** |
| `fastapi`, `uvicorn` | TTS 서버 (tts_server/ 유지) | tts-venv 기설치 |
| `pytest`, `pytest-asyncio` | 테스트 | tts-venv 기설치 |

`openai` Python SDK 미사용 — `httpx`로 HMG Hub API 직접 호출 (Authorization 헤더만 필요).

## SSL 처리

HMG 사내망 프록시(자체 CA)로 인해 `edge_tts`의 기본 SSL 컨텍스트 검증 실패. 기존 TypeScript와 동일하게 패치:

```python
import ssl, edge_tts.communicate as ec
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
ec._SSL_CTX = ctx  # 모듈 레벨 상수 교체
```

## Shell Script 변경

모든 `hooks/*.sh`에서:
```bash
# 기존
nohup node "$SCRIPT_DIR/../dist/index.js" <mode> > /dev/null 2>&1 &
# 변경
VENV_PY="$SCRIPT_DIR/../tts-venv/bin/python"
nohup "$VENV_PY" -m hook_voice <mode> > /dev/null 2>&1 &
```

## 제거 대상

| 항목 | 처리 |
|------|------|
| `src/*.ts` (8개) | 삭제 |
| `tests/*.test.ts` (10개) | 삭제 |
| `vitest.config.ts` | 삭제 |
| `package.json`, `package-lock.json`, `tsconfig.json` | 삭제 |
| `node_modules/` | 삭제 (gitignore됨) |
| `dist/` | 삭제 |
| `server.sh` npm build 단계 | 제거 |

## 유지 대상

- `tts_server/` — 변경 없음
- `hooks/*.sh` — python 경로로만 수정
- `server.sh` — npm 단계 제거 후 유지
- `.voice-persona.json`, `voice-map.json`, `skills-catalog.json` — 유지
- `setup-tts.sh` — httpx 추가 설치 라인 추가

## 테스트 전략

- `pytest` + `pytest-asyncio`로 async 함수 테스트
- `httpx.MockTransport` 또는 `unittest.mock.AsyncMock`으로 LLM/TTS HTTP 호출 mock
- `edge_tts` mock: `AsyncMock`으로 `Communicate.save()` 대체
- 분류 함수(`classify_pre_tool_bash`, `classify_post_tool_bash`)는 순수 함수 → mock 불필요
- 파일 I/O 테스트: `tmp_path` fixture (pytest 내장) 활용
