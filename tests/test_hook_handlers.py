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
    handle_subagent_stop,
    handle_config,
    handle_control,
)
import hook_voice.hook_handlers as _hh

_CFG = Config()


@pytest.fixture(autouse=True)
def reset_classify_cache():
    _hh._classify_rules_cache = None
    yield
    _hh._classify_rules_cache = None


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

def test_classify_git_push_force():
    assert classify_pre_tool_bash("git push origin main --force") == \
        "주의: 강제 push — 원격 이력이 변경됩니다."

def test_classify_kubectl_delete():
    assert classify_pre_tool_bash("kubectl delete pod my-pod") == \
        "주의: 쿠버네티스 리소스를 삭제합니다."

def test_classify_returns_none_for_unknown():
    assert classify_pre_tool_bash("echo hello world") is None

def test_classify_post_build_success():
    assert classify_post_tool_bash("npm run build", "", 0) == "빌드가 완료됐습니다."

def test_classify_post_build_failure():
    assert classify_post_tool_bash("tsc", "", 1) == "빌드가 실패했습니다. 에러를 확인해 주세요."

def test_classify_post_test_passed():
    result = classify_post_tool_bash("pytest", "5 passed in 1.2s", 0)
    assert result == "전체 5개 통과했습니다."

def test_classify_post_test_failed():
    result = classify_post_tool_bash("pytest", "2 failed, 3 passed", 1)
    assert result is not None
    assert "2개 실패했습니다" in result
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
        mock.assert_called_once_with("Claude가 응답했습니다", _CFG.tts_speed,
                                     edge_timeout=_CFG.edge_timeout_ms / 1000)

async def test_handle_notification_uses_title_as_fallback():
    raw = json.dumps({"title": "알림 제목"})
    with patch("hook_voice.hook_handlers.speak_hook", new=AsyncMock()) as mock:
        await handle_notification(raw, _CFG)
        mock.assert_called_once_with("알림 제목", _CFG.tts_speed,
                                     edge_timeout=_CFG.edge_timeout_ms / 1000)

async def test_handle_hook_skips_short_text():
    raw = json.dumps({"last_assistant_message": "짧음"})
    with patch("hook_voice.hook_handlers.speak_hook", new=AsyncMock()) as mock:
        await handle_hook(raw, _CFG)
        mock.assert_not_called()


async def test_handle_hook_uses_transcript_fallback(tmp_path):
    transcript = tmp_path / "session.jsonl"
    transcript.write_text(
        json.dumps({
            "message": {
                "role": "assistant",
                "content": [{"type": "text", "text": "충분히 긴 응답입니다. " * 4}],
            }
        }),
        encoding="utf-8",
    )
    raw = json.dumps({"last_assistant_message": ""})
    with patch("hook_voice.hook_handlers._derive_transcript_path", return_value=transcript), \
         patch("hook_voice.hook_handlers.extract_summary", new=AsyncMock(return_value="요약")), \
         patch("hook_voice.hook_handlers.speak_hook", new=AsyncMock()) as mock:
        await handle_hook(raw, _CFG)
        mock.assert_called_once()


# ── handle_subagent_stop 테스트 ──────────────────────────────

MOCK_VOICE_MAP = {
    "supertonic": {"lang": "ko", "steps": 10},
    "voices": {"default": "F1", "reviewer": "M2", "builder": "M4", "tester": "F2"},
    "voice_names": {"F1": "연아", "M2": "빌", "M4": "리누스", "F2": "마리"},
    "instructs": {"default": "밝고 친절하게", "reviewer": "천천히 신중하게", "builder": "빠르고 자신감 있게"},
    "categories": {
        "reviewer": ["feature-reviewer", "code-reviewer"],
        "builder": ["feature-builder"],
        "tester": ["feature-tester"],
    },
}


async def test_subagent_stop_skips_short_text():
    """min_chars 미만 텍스트는 TTS 호출 없이 반환."""
    raw = json.dumps({"last_assistant_message": "짧음"})
    with patch("hook_voice.hook_handlers.speak_agent", new_callable=AsyncMock) as mock_speak:
        await handle_subagent_stop(raw, "feature-reviewer", _CFG)
        mock_speak.assert_not_called()


async def test_subagent_stop_uses_correct_voice_for_reviewer():
    """feature-reviewer → M2(빌) voice 사용."""
    long_text = "코드 리뷰를 완료했습니다. " * 5  # 60자 이상
    raw = json.dumps({"last_assistant_message": long_text})
    with patch("hook_voice.hook_handlers.load_voice_map", return_value=MOCK_VOICE_MAP), \
         patch("hook_voice.hook_handlers.speak_agent", new_callable=AsyncMock) as mock_speak, \
         patch("hook_voice.hook_handlers.extract_one_liner", new_callable=AsyncMock, return_value="리뷰 완료"):
        await handle_subagent_stop(raw, "feature-reviewer", _CFG)
        mock_speak.assert_called_once()
        call_args = mock_speak.call_args
        spoken_text = call_args.args[0] if call_args.args else call_args[0][0]
        used_voice = call_args.args[1] if call_args.args else call_args[0][1]
    assert used_voice == "M2"
    assert "빌" in spoken_text


async def test_subagent_stop_falls_back_to_default_on_unknown_agent():
    """알 수 없는 agent_type → default voice(F1) 사용."""
    raw = json.dumps({"last_assistant_message": "A" * 60})
    with patch("hook_voice.hook_handlers.load_voice_map", return_value=MOCK_VOICE_MAP), \
         patch("hook_voice.hook_handlers.speak_agent", new_callable=AsyncMock) as mock_speak, \
         patch("hook_voice.hook_handlers.extract_one_liner", new_callable=AsyncMock, return_value="완료"):
        await handle_subagent_stop(raw, "unknown-xyz", _CFG)
        mock_speak.assert_called_once()
        call_args = mock_speak.call_args
        used_voice = call_args.args[1] if call_args.args else call_args[0][1]
    assert used_voice == "F1"


async def test_subagent_stop_empty_one_liner_still_speaks():
    """extract_one_liner가 빈 문자열 반환해도 '{label} {name}입니다.' 발화."""
    raw = json.dumps({"last_assistant_message": "B" * 60})
    with patch("hook_voice.hook_handlers.load_voice_map", return_value=MOCK_VOICE_MAP), \
         patch("hook_voice.hook_handlers.speak_agent", new_callable=AsyncMock) as mock_speak, \
         patch("hook_voice.hook_handlers.extract_one_liner", new_callable=AsyncMock, return_value=""):
        await handle_subagent_stop(raw, "feature-builder", _CFG)
        mock_speak.assert_called_once()
        call_args = mock_speak.call_args
        spoken_text = call_args.args[0] if call_args.args else call_args[0][0]
    assert "빌더" in spoken_text
    assert "리누스" in spoken_text


async def test_subagent_stop_adds_sigh_on_failure():
    """실패 키워드가 있으면 발화 텍스트에 <sigh>가 포함된다."""
    raw = json.dumps({"last_assistant_message": "D" * 60})
    with patch("hook_voice.hook_handlers.load_voice_map", return_value=MOCK_VOICE_MAP), \
         patch("hook_voice.hook_handlers.speak_agent", new_callable=AsyncMock) as mock_speak, \
         patch("hook_voice.hook_handlers.extract_one_liner_with_tag", new_callable=AsyncMock, return_value=("빌드 실패", "<sigh>")):
        await handle_subagent_stop(raw, "feature-builder", _CFG)
        spoken_text = mock_speak.call_args.args[0]
    assert "<sigh>" in spoken_text


async def test_subagent_stop_adds_laugh_for_tester_success():
    """tester + 통과 → <laugh>가 발화 텍스트에 포함된다."""
    raw = json.dumps({"last_assistant_message": "E" * 60})
    with patch("hook_voice.hook_handlers.load_voice_map", return_value=MOCK_VOICE_MAP), \
         patch("hook_voice.hook_handlers.speak_agent", new_callable=AsyncMock) as mock_speak, \
         patch("hook_voice.hook_handlers.extract_one_liner_with_tag", new_callable=AsyncMock, return_value=("전체 테스트 통과", "<laugh>")):
        await handle_subagent_stop(raw, "feature-tester", _CFG)
        spoken_text = mock_speak.call_args.args[0]
    assert "<laugh>" in spoken_text


async def test_subagent_stop_builder_neutral_uses_breath_tag():
    """builder + 중립 콘텐츠 → voice 특성에 맞게 <breath> 태그가 발화 텍스트에 포함된다."""
    raw = json.dumps({"last_assistant_message": "F" * 60})
    with patch("hook_voice.hook_handlers.load_voice_map", return_value=MOCK_VOICE_MAP), \
         patch("hook_voice.hook_handlers.speak_agent", new_callable=AsyncMock) as mock_speak, \
         patch("hook_voice.hook_handlers.extract_one_liner_with_tag", new_callable=AsyncMock, return_value=("구현 완료", "<breath>")):
        await handle_subagent_stop(raw, "feature-builder", _CFG)
        spoken_text = mock_speak.call_args.args[0]
    assert "<breath>" in spoken_text


async def test_subagent_stop_passes_steps_from_voice_map():
    """handle_subagent_stop이 voice-map의 supertonic.steps를 speak_agent로 전달한다."""
    raw = json.dumps({"last_assistant_message": "C" * 60})
    with patch("hook_voice.hook_handlers.load_voice_map", return_value=MOCK_VOICE_MAP), \
         patch("hook_voice.hook_handlers.speak_agent", new_callable=AsyncMock) as mock_speak, \
         patch("hook_voice.hook_handlers.extract_one_liner", new_callable=AsyncMock, return_value="완료"):
        await handle_subagent_stop(raw, "feature-reviewer", _CFG)
        mock_speak.assert_called_once()
        used_steps = mock_speak.call_args.kwargs.get("steps")
    assert used_steps == 10


async def test_subagent_stop_recovers_agent_type_from_transcript(tmp_path):
    transcript = tmp_path / "session.jsonl"
    transcript.write_text(
        json.dumps({
            "content": [
                {
                    "type": "tool_use",
                    "name": "Agent",
                    "input": {"subagent_type": "feature-reviewer"},
                }
            ]
        }),
        encoding="utf-8",
    )
    raw = json.dumps({
        "last_assistant_message": "리뷰 완료 메시지입니다. " * 4,
        "transcript_path": str(transcript),
    })
    with patch("hook_voice.hook_handlers.load_voice_map", return_value=MOCK_VOICE_MAP), \
         patch("hook_voice.hook_handlers.speak_agent", new_callable=AsyncMock) as mock_speak, \
         patch("hook_voice.hook_handlers.extract_one_liner", new_callable=AsyncMock, return_value="리뷰 완료"):
        await handle_subagent_stop(raw, "", _CFG)
        mock_speak.assert_called_once()
        used_voice = mock_speak.call_args.args[1]
    assert used_voice == "M2"


# ── handle_config 테스트 ─────────────────────────────────────

class TestHandleConfig:
    @pytest.mark.asyncio
    async def test_list_shows_all_keys(self, tmp_path, capsys):
        cfg_path = tmp_path / ".voice-persona.json"
        await handle_config([], cfg_path)
        out = capsys.readouterr().out
        assert "ttsSpeed" in out
        assert "autoSpeak" in out

    @pytest.mark.asyncio
    async def test_set_saves_value(self, tmp_path):
        cfg_path = tmp_path / ".voice-persona.json"
        await handle_config(["set", "ttsSpeed", "1.5"], cfg_path)
        data = json.loads(cfg_path.read_text())
        assert data["ttsSpeed"] == 1.5

    @pytest.mark.asyncio
    async def test_get_returns_value(self, tmp_path, capsys):
        cfg_path = tmp_path / ".voice-persona.json"
        cfg_path.write_text('{"ttsSpeed": 1.5}')
        await handle_config(["get", "ttsSpeed"], cfg_path)
        out = capsys.readouterr().out.strip()
        assert out == "1.5"

    @pytest.mark.asyncio
    async def test_reset_deletes_file(self, tmp_path, capsys):
        cfg_path = tmp_path / ".voice-persona.json"
        cfg_path.write_text('{"ttsSpeed": 1.5}')
        await handle_config(["reset"], cfg_path)
        assert not cfg_path.exists()

    @pytest.mark.asyncio
    async def test_set_bool_false(self, tmp_path):
        cfg_path = tmp_path / ".voice-persona.json"
        await handle_config(["set", "autoSpeak", "false"], cfg_path)
        data = json.loads(cfg_path.read_text())
        assert data["autoSpeak"] is False

    @pytest.mark.asyncio
    async def test_get_unknown_key_prints_error(self, tmp_path, capsys):
        cfg_path = tmp_path / ".voice-persona.json"
        with pytest.raises(SystemExit) as exc_info:
            await handle_config(["get", "nonExistentKey"], cfg_path)
        assert exc_info.value.code == 1
        err = capsys.readouterr().err
        assert "알 수 없는 키" in err


# ── handle_control 테스트 ─────────────────────────────────────

class TestHandleControl:
    @pytest.mark.asyncio
    async def test_flush_removes_wav_mp3(self, tmp_path, capsys):
        (tmp_path / "file1.wav").write_bytes(b"")
        (tmp_path / "file2.mp3").write_bytes(b"")

        with patch("hook_voice.hook_handlers.SPOOL_DIR", tmp_path):
            await handle_control("flush")

        out = capsys.readouterr().out
        assert "2개 제거" in out
        assert not (tmp_path / "file1.wav").exists()
        assert not (tmp_path / "file2.mp3").exists()

    @pytest.mark.asyncio
    async def test_flush_with_empty_spool(self, tmp_path, capsys):
        with patch("hook_voice.hook_handlers.SPOOL_DIR", tmp_path):
            await handle_control("flush")

        out = capsys.readouterr().out
        assert "0개 제거" in out

    @pytest.mark.asyncio
    async def test_no_pid_file_prints_message(self, tmp_path, capsys):
        with patch("hook_voice.hook_handlers.SPOOL_DIR", tmp_path):
            await handle_control("pause")

        out = capsys.readouterr().out
        assert "재생 중인 TTS가 없습니다" in out

    @pytest.mark.asyncio
    async def test_pause_sends_sigstop(self, tmp_path, capsys):
        pid_file = tmp_path / ".player.pid"
        pid_file.write_text("12345")

        with patch("hook_voice.hook_handlers.SPOOL_DIR", tmp_path), \
             patch("os.kill") as mock_kill:
            import signal
            await handle_control("pause")
            mock_kill.assert_called_once_with(12345, signal.SIGSTOP)

        out = capsys.readouterr().out
        assert "일시정지" in out
        assert "12345" in out

    @pytest.mark.asyncio
    async def test_resume_sends_sigcont(self, tmp_path, capsys):
        pid_file = tmp_path / ".player.pid"
        pid_file.write_text("12345")

        with patch("hook_voice.hook_handlers.SPOOL_DIR", tmp_path), \
             patch("os.kill") as mock_kill:
            import signal
            await handle_control("resume")
            mock_kill.assert_called_once_with(12345, signal.SIGCONT)

        out = capsys.readouterr().out
        assert "재개" in out

    @pytest.mark.asyncio
    async def test_skip_sends_sigkill_and_removes_pid_file(self, tmp_path, capsys):
        pid_file = tmp_path / ".player.pid"
        pid_file.write_text("12345")

        with patch("hook_voice.hook_handlers.SPOOL_DIR", tmp_path), \
             patch("os.kill") as mock_kill:
            import signal
            await handle_control("skip")
            mock_kill.assert_called_once_with(12345, signal.SIGKILL)

        out = capsys.readouterr().out
        assert "건너뛰었습니다" in out
        assert not pid_file.exists()

    @pytest.mark.asyncio
    async def test_invalid_action_exits_with_error(self, tmp_path, capsys):
        with patch("hook_voice.hook_handlers.SPOOL_DIR", tmp_path):
            with pytest.raises(SystemExit) as exc_info:
                await handle_control("unknown")
        assert exc_info.value.code == 1

    @pytest.mark.asyncio
    async def test_process_already_gone_removes_pid_file(self, tmp_path, capsys):
        pid_file = tmp_path / ".player.pid"
        pid_file.write_text("99999")

        with patch("hook_voice.hook_handlers.SPOOL_DIR", tmp_path), \
             patch("os.kill", side_effect=ProcessLookupError):
            await handle_control("pause")

        out = capsys.readouterr().out
        assert "이미 종료" in out
        assert not pid_file.exists()


async def test_handle_hook_calls_pipeline_when_retouch_enabled():
    """speech_retouch=True이면 SpeechPipeline이 호출된다."""
    from hook_voice.config import Config
    from hook_voice.hook_handlers import handle_hook
    from hook_voice.speech.pipeline import SpeechContext

    config = Config(auto_speak=True, min_chars=5, speech_retouch=True)
    mock_ctx = SpeechContext(text="정제됨", ssml="정제됨")
    mock_pipeline = AsyncMock()
    mock_pipeline.process = AsyncMock(return_value=mock_ctx)

    with patch("hook_voice.hook_handlers.extract_summary", new=AsyncMock(return_value="요약")), \
         patch("hook_voice.hook_handlers.get_default_pipeline", return_value=mock_pipeline), \
         patch("hook_voice.hook_handlers.speak_hook", new=AsyncMock()) as mock_speak:
        await handle_hook('{"last_assistant_message": "충분히 긴 텍스트입니다"}', config)
        mock_pipeline.process.assert_called_once_with("요약")
        mock_speak.assert_called_once()
        assert mock_speak.call_args[0][0] == "정제됨"


async def test_handle_hook_skips_pipeline_when_retouch_disabled():
    """speech_retouch=False이면 SpeechPipeline이 호출되지 않는다."""
    from hook_voice.config import Config
    from hook_voice.hook_handlers import handle_hook

    config = Config(auto_speak=True, min_chars=5, speech_retouch=False)
    mock_pipeline = AsyncMock()

    with patch("hook_voice.hook_handlers.extract_summary", new=AsyncMock(return_value="요약")), \
         patch("hook_voice.hook_handlers.get_default_pipeline", return_value=mock_pipeline), \
         patch("hook_voice.hook_handlers.speak_hook", new=AsyncMock()) as mock_speak:
        await handle_hook('{"last_assistant_message": "충분히 긴 텍스트입니다"}', config)
        mock_pipeline.process.assert_not_called()
        assert mock_speak.call_args[0][0] == "요약"


async def test_handle_subagent_stop_uses_extract_one_liner():
    """handle_subagent_stop이 extract_one_liner로 요약해 speak_agent를 호출한다."""
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
         patch("hook_voice.hook_handlers.resolve_voice_settings", return_value={"steps": 12, "synth_speed": 1.05}), \
         patch("hook_voice.hook_handlers.extract_one_liner_with_tag", new_callable=AsyncMock, return_value=("작업 완료", "<breath>")) as mock_llm, \
         patch("hook_voice.hook_handlers.speak_agent", new=AsyncMock()) as mock_speak_agent:
        await handle_subagent_stop('{"last_assistant_message": "충분히 긴 내용입니다"}', "default", config)
        mock_llm.assert_called_once()
        mock_speak_agent.assert_called_once()
        assert "작업 완료" in mock_speak_agent.call_args[0][0]
