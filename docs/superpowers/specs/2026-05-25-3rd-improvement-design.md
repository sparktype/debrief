# summary-voice-mcp 3차 개선 설계

날짜: 2026-05-25  
접근법: B — 단계적 종합 (Sprint 1: 버그·안정성 → Sprint 2: UX·기능)

## 배경

4개 분석가(아키텍처·코드품질·성능보안·기능UX)의 병렬 분석 결과 38개 이슈 도출.
Sprint 1은 안전성과 정확성을 확보하고, Sprint 2는 사용성을 개선한다.

---

## Sprint 1 — 버그·안정성 (10개)

### S1-1: stop.sh + prompt-submit.sh stdin payload 전달

**문제**: stop.sh가 Claude Code의 hook payload(JSON)를 읽지 않고 버림. handle_hook이 빈 raw로 폴백해 transcript 파일을 추가 파싱함. prompt-submit.sh도 동일하게 stdin 미전달로 hook-suggest의 prompt_hint가 항상 비어 있음.

**변경 파일**: `hooks/stop.sh`, `hooks/prompt-submit.sh`

**설계**:
```bash
# 두 파일 모두 동일 패턴 적용
PAYLOAD=$(cat)
echo "$PAYLOAD" | nohup "$VENV_PY" -m hook_voice <subcommand> >> /tmp/voice-notification-debug.log 2>&1 &
disown $!; exit 0
```

**검증**: `echo '{"last_assistant_message":"테스트"}' | bash hooks/stop.sh` 실행 후 로그 확인.

---

### S1-2: tempfile.mktemp() → NamedTemporaryFile 교체

**문제**: `player.py`의 `_generate_edge`와 `speak_agent` 내부에서 `tempfile.mktemp()`를 사용. 파일을 생성하지 않고 경로만 반환해 TOCTOU 취약점 존재.

**변경 파일**: `hook_voice/player.py`

**설계**:
```python
# _generate_edge
import tempfile
with tempfile.NamedTemporaryFile(delete=False, suffix=".mp3", prefix="vp_edge_") as f:
    out = Path(f.name)
# speak_agent 내부 wav 생성도 동일 패턴
```

**검증**: 기존 `test_player.py` 통과 확인.

---

### S1-3: asyncio.get_event_loop() → get_running_loop()

**문제**: `__main__.py:20`의 `_read_stdin`에서 deprecated API 사용. Python 3.12+에서 RuntimeError.

**변경 파일**: `hook_voice/__main__.py`

**설계**:
```python
loop = asyncio.get_running_loop()  # get_event_loop() → get_running_loop()
data = await loop.run_in_executor(None, sys.stdin.buffer.read)
```

**검증**: `python -m hook_voice hook` 실행 정상 동작 확인.

---

### S1-4: asyncio.Event 전역 → main() 내부 이동

**문제**: `supervisor.py:20`의 `_shutdown_event`가 모듈 임포트 시 생성. 테스트에서 `asyncio.run()` 여러 번 호출 시 이벤트 전달 실패.

**변경 파일**: `tts_server/supervisor.py`

**설계**:
- `_shutdown_event = asyncio.Event()` 모듈 레벨 선언 제거
- `main()` 내부에서 `shutdown = asyncio.Event()` 생성
- `player_loop`, `cleanup_loop`, `monitor_children`에 `shutdown` 명시 전달
- 시그널 핸들러도 `shutdown.set()`으로 교체

**검증**: `test_supervisor.py` 전체 통과. player_loop/cleanup_loop 단위 테스트에서 shutdown 격리 확인.

---

### S1-5: spool meta 파일 → 파일명에 speed 인코딩

**문제**: `_enqueue_spool`에서 `rename` 후 `.meta` 파일 `write_text` 사이 비원자성. Player가 `.meta` 없는 파일을 읽으면 `config.tts_speed` 무시하고 하드코딩 기본값 적용.

**변경 파일**: `hook_voice/player.py`, `tts_server/supervisor.py`

**설계**:
```python
# player.py _enqueue_spool
def _enqueue_spool(audio_file: Path, speed: float) -> None:
    SPOOL_DIR.mkdir(exist_ok=True)
    uid = f"{int(time.time() * 1000)}_{''.join(random.choices(..., k=5))}"
    # speed를 파일명에 포함: {uid}_{speed_x10}.wav (소수점 제거)
    speed_tag = str(round(speed * 100))  # 1.2 → 120, 1.0 → 100, 1.25 → 125 (소수점 두 자리 정밀도 보장)
    dest = SPOOL_DIR / f"{uid}_{speed_tag}{audio_file.suffix}"
    audio_file.rename(dest)
    # .meta 파일 생성 제거

# supervisor.py player_loop
files = sorted(spool.glob("*.wav") + spool.glob("*.mp3"))
if files:
    audio = files[0]
    # 파일명에서 speed 파싱: uid_speedtag.ext
    parts = audio.stem.rsplit("_", 1)
    speed = str(int(parts[-1]) / 100) if len(parts) == 2 and parts[-1].isdigit() else "1.0"
    # .meta 파일 읽기 제거
```

**검증**: `_enqueue_spool` 단위 테스트 — meta 파일이 생성되지 않음 확인. player_loop 테스트 — 파일명에서 speed 파싱 정확도 확인.

---

### S1-6: afplay terminate 후 proc.wait() 추가

**문제**: `supervisor.py`의 player_loop에서 `proc.terminate()` 후 `proc.wait()`를 하지 않아 좀비 프로세스 위험.

**변경 파일**: `tts_server/supervisor.py`

**설계**:
```python
if shutdown.is_set() and proc.returncode is None:
    proc.terminate()
    try:
        await asyncio.wait_for(proc.wait(), timeout=2.0)
    except asyncio.TimeoutError:
        proc.kill()
        await proc.wait()
```

**검증**: shutdown 시나리오 테스트에서 좀비 프로세스 없음 확인.

---

### S1-7: API 키 누락 시 warning 로그 + 조기 반환

**문제**: `HUB_API_KEY` 미설정 시 "Bearer " 빈값으로 요청 전송. 오류 로그 없어 원인 파악 불가.

**변경 파일**: `hook_voice/llm_client.py`

**설계**:
```python
import logging
_log = logging.getLogger(__name__)

async def chat_completion(...) -> str:
    api_key = os.environ.get("HUB_API_KEY", "")
    if not api_key:
        _log.warning("HUB_API_KEY 미설정 — LLM 호출 건너뜀")
        return ""
    ...
```

**검증**: `test_llm_client.py`에 API 키 미설정 케이스 추가. warning 로그 발생 확인.

---

### S1-8: Config timeout 값을 player.py에 실제 적용

**문제**: `config.edge_timeout_ms`, `config.supertonic_timeout_ms`가 설정 가능하지만 `player.py`의 하드코딩된 10.0/20.0/0.5초에 반영되지 않음.

**변경 파일**: `hook_voice/player.py`, `hook_voice/hook_handlers.py`

**설계**:
- `speak_hook(text, voice, speed, edge_timeout=10.0, health_timeout=0.5)` 파라미터 추가
- `speak_agent(text, voice, port, speed, instruct, supertonic_timeout=20.0)` 파라미터 추가
- `handle_hook`, `handle_subagent_stop`에서 `config.edge_timeout_ms / 1000` 전달

**검증**: config에서 `edgeTimeoutMs: 5000` 설정 시 5초 타임아웃 적용 확인.

---

### S1-9: _FALLBACK_MAP "멜린다" → "연아" 동기화

**문제**: `voice_router.py:34`의 `_FALLBACK_MAP`에 F1이 "멜린다"로 하드코딩. `voice-map.json`은 이미 "연아"로 변경됨.

**변경 파일**: `hook_voice/voice_router.py`

**설계**:
```python
_FALLBACK_MAP: VoiceMap = {
    ...
    "voice_names": {"F1": "연아"},  # 멜린다 → 연아
    ...
}
```

**검증**: `test_voice_router.py`에 폴백 시 이름 확인 테스트 추가.

---

### S1-10: handle_subagent_stop 테스트 추가

**문제**: `handle_subagent_stop`의 핵심 분기(agent_type 복구, extract_one_liner 빈 반환, speak_agent 폴백)가 테스트 전무.

**변경 파일**: `tests/test_hook_handlers.py`

**설계**: 추가할 테스트 케이스:
1. agent_type="" + transcript 복구 성공 → 올바른 voice 사용
2. agent_type="" + transcript 복구 실패 → default voice 사용
3. extract_one_liner가 "" 반환 → speak_agent가 빈 텍스트로 호출되지 않음
4. len(text) < min_chars → 조기 반환 확인

---

## Sprint 2 — UX·기능 (7개)

### S2-1: python -m hook_voice control (pause/flush/skip)

**문제**: 재생 중인 TTS를 멈추거나 큐를 비울 방법이 없음.

**변경 파일**: `hook_voice/__main__.py`, `hook_voice/hook_handlers.py`, `server.sh`

**설계**:
```
# 새 서브커맨드
python -m hook_voice control pause   # afplay PID에 SIGSTOP
python -m hook_voice control resume  # afplay PID에 SIGCONT
python -m hook_voice control flush   # spool 디렉토리 미재생 파일 전체 삭제
python -m hook_voice control skip    # 현재 afplay만 SIGKILL
```

구현 전략:
- `SPOOL_DIR / ".player.pid"` 파일에 현재 afplay PID 기록 (supervisor.py 수정, SPOOL_DIR 내에 두어 경로 일관성 확보)
- control 커맨드가 PID 파일을 읽어 시그널 전송
- flush는 `spool.glob("*.wav") + spool.glob("*.mp3")`를 모두 unlink
- `server.sh pause/resume/flush/skip` 래퍼 추가

**검증**: 재생 중 `./server.sh flush` 실행 후 spool 비어있음 확인. `./server.sh skip` 후 다음 파일 재생됨 확인.

---

### S2-2: python -m hook_voice config get/set/list/reset

**문제**: .voice-persona.json을 직접 편집해야 하며 JSON 오류 시 전체 기본값 복원.

**변경 파일**: `hook_voice/__main__.py`, `hook_voice/hook_handlers.py`, `server.sh`

**설계**:
```
python -m hook_voice config list                  # 현재 설정 전체 출력
python -m hook_voice config get autoSpeak         # 단일 값 조회
python -m hook_voice config set autoSpeak false   # 값 변경 (타입 자동 변환)
python -m hook_voice config reset                 # 기본값으로 초기화
```

구현 전략:
- `handle_config` 함수 신설. `load_config()` → 값 변경 → JSON 저장
- 타입 변환: "true"/"false" → bool, 숫자 문자열 → int/float
- `_KEY_MAP` 역방향 매핑으로 Python key ↔ JSON key 변환
- 알 수 없는 key 입력 시 오류 메시지 출력

**검증**: `config set ttsSpeed 1.5` 후 `.voice-persona.json`의 `ttsSpeed`가 1.5로 변경됨 확인.

---

### S2-3: server.sh status 큐 길이·재생 중 상태 추가

**문제**: 현재 status가 포트 리스닝 여부만 확인. "왜 발화가 없지?" 진단이 어려움.

**변경 파일**: `server.sh`

**설계**: status 출력 추가:
```
[TTS 큐]
  대기: 3개
  마지막 발화: ~/.local/share/voice-persona/last_message.txt 내용 (30자)
[컴포넌트]
  uvicorn (7777): OK / FAIL
  supertonic (7788): OK / FAIL
  supervisor: running (PID 12345) / not running
```

구현: bash에서 `ls /tmp/tts-spool/*.wav 2>/dev/null | wc -l`, `cat ~/.local/share/voice-persona/last_message.txt` 등 직접 조회.

---

### S2-4: python -m hook_voice health 진단 커맨드

**문제**: TTS가 작동 안 할 때 원인을 로그 파일을 직접 열어야 파악 가능.

**변경 파일**: `hook_voice/__main__.py`, `hook_voice/hook_handlers.py`

**설계**:
```
python -m hook_voice health
# 출력:
[1] HUB_API_KEY 환경변수: OK / MISSING
[2] LLM API 연결 (HUB_BASE_URL): OK (200) / FAIL (타임아웃)
[3] EdgeTTS 연결: OK / FAIL (SSL 오류 등)
[4] uvicorn (7777): OK / FAIL
[5] supertonic (7788): OK / FAIL
[6] spool 디렉토리: /tmp/tts-spool/ (3개 대기)
```

각 항목을 순서대로 테스트하고 결과를 stdout 출력. `asyncio.gather`로 병렬 체크.

---

### S2-5: server.sh install 전체 hook 자동 등록

**문제**: install이 stop.sh만 등록. notification, subagent-stop, pre/post-tool-bash가 수동 등록 필요.

**변경 파일**: `server.sh`

**설계**: `settings.json`에 모든 hook 일괄 등록:
```json
{
  "Stop": [{"type": "command", "command": "...stop.sh", "timeout": 15}],
  "SubagentStop": [{"type": "command", "command": "...subagent-stop.sh", "timeout": 15}],
  "Notification": [{"type": "command", "command": "...notification.sh", "timeout": 10}],
  "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "...pre-tool-bash.sh"}]}],
  "PostToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "...post-tool-bash.sh"}]}],
  "UserPromptSubmit": [{"type": "command", "command": "...prompt-submit.sh", "timeout": 10}],
  "SessionStart": [{"type": "command", "command": "...session-start.sh", "timeout": 10}]
}
```

`python -c`로 JSON 파싱해 기존 settings.json과 병합. 중복 등록 방지.

---

### S2-6: 발화 히스토리 기록 (history.jsonl)

**문제**: last_message.py가 마지막 텍스트 하나만 저장. "아까 뭐라고 했더라" 확인 불가.

**변경 파일**: `hook_voice/last_message.py`, `hook_voice/__main__.py`

**설계**:
```python
# last_message.py에 추가
def append_history(text: str) -> None:
    history_file = _get_data_dir() / "history.jsonl"
    entry = {"ts": datetime.now(timezone.utc).isoformat(), "text": text}
    with open(history_file, "a", encoding="utf-8") as f:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")
```

- `save_last_message` 호출 시 `append_history`도 함께 호출
- `python -m hook_voice history [--last N]` 서브커맨드로 최근 N개 출력 (기본 10)
- 파일 크기 제한: 1000줄 초과 시 가장 오래된 100줄 제거 → 900줄 유지 (rotate, 누적 파일 무한 성장 방지)

---

### S2-7: pre-tool-bash 위험 패턴 확장 + 외부 JSON

**문제**: `classify_pre_tool_bash`가 4개 패턴만 탐지. `kubectl delete`, `git push --force` 등 누락.

**변경 파일**: `hook_voice/hook_handlers.py`, 새 파일 `classify-rules.json`

**설계**:
```json
// classify-rules.json
{
  "pre_tool": [
    {"pattern": "rm\\s+-rf|git\\s+reset\\s+--hard|DROP\\s+TABLE", "message": "주의: 되돌릴 수 없는 작업입니다."},
    {"pattern": "git\\s+push.*--force", "message": "주의: 강제 push — 원격 이력이 변경됩니다."},
    {"pattern": "kubectl\\s+delete|docker.*rm\\s+-f", "message": "주의: 리소스를 삭제합니다."},
    {"pattern": "npm run build|tsc\\b|cargo build|go build", "message": "빌드를 시작합니다."},
    {"pattern": "npm\\s+test|vitest|pytest|cargo\\s+test|go\\s+test", "message": "테스트를 실행합니다."},
    {"pattern": "npm\\s+install|npm\\s+ci|pip\\s+install|uv\\s+sync", "message": "패키지를 설치합니다."}
  ]
}
```

`classify_pre_tool_bash`가 JSON을 로드해 패턴을 순서대로 매칭. JSON 로드 실패 시 현재 하드코딩 로직으로 폴백.

---

## 공통 설계 원칙

- **테스트 필수**: 각 Sprint 항목은 pytest로 검증 후 완료 처리
- **폴백 유지**: 새 기능 실패 시 기존 동작 유지 (예: classify-rules.json 없으면 하드코딩 패턴 사용)
- **로그 추가**: 기존 `except Exception: pass`에 최소 `logging.debug` 추가
- **커밋 단위**: 항목별 독립 커밋 (S1-1, S1-2 … S2-7)

---

## 검증 기준

Sprint 1 완료 조건:
- `pytest tests/ tts_server/test_server.py tts_server/test_supervisor.py -v` 전체 통과
- `./server.sh status` 정상 동작
- `echo '{"last_assistant_message":"테스트입니다"}' | python -m hook_voice hook` 발화 확인

Sprint 2 완료 조건:
- `./server.sh flush` → spool 비워짐 확인
- `python -m hook_voice config set ttsSpeed 1.5` → `.voice-persona.json` 반영 확인
- `python -m hook_voice health` → 모든 컴포넌트 상태 출력 확인
- `./server.sh install` → settings.json에 7종 hook 등록 확인
