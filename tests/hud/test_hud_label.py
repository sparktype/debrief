# tests/hud/test_hud_label.py
# hud-label 서브커맨드 핸들러 단위 테스트
import json
import sys
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
import httpx


# ── 헬퍼 ────────────────────────────────────────────────────────────────────

def _make_config():
    from hook_voice.config import load_config
    return load_config()


# ── handle_hud_label 테스트 ──────────────────────────────────────────────────

async def test_api_success_returns_label(capsys):
    """API 200 응답 → label 필드를 JSON으로 출력한다."""
    mock_resp = MagicMock()
    mock_resp.status_code = 200
    mock_resp.json.return_value = {"label": "🔊 normal [F1]"}

    async def _fake_get(url, timeout):
        return mock_resp

    with patch("hook_voice.hook_handlers.httpx.AsyncClient") as MockClient:
        instance = AsyncMock()
        instance.get = AsyncMock(side_effect=_fake_get)
        instance.__aenter__ = AsyncMock(return_value=instance)
        instance.__aexit__ = AsyncMock(return_value=False)
        MockClient.return_value = instance

        from hook_voice.hook_handlers import handle_hud_label
        await handle_hud_label()

    captured = capsys.readouterr()
    assert captured.err == ""
    data = json.loads(captured.out.strip())
    assert isinstance(data.get("label"), str)
    assert data["label"] == "🔊 normal [F1]"


async def test_api_timeout_falls_back_to_snapshot(tmp_path, capsys):
    """API timeout → snapshot 폴백 → build_label() 결과를 출력한다."""
    snapshot = {"mode": "focus", "voice": "M2", "auto_speak": True}

    async def _timeout_get(url, timeout):
        raise httpx.TimeoutException("timeout")

    with patch("hook_voice.hook_handlers.httpx.AsyncClient") as MockClient:
        instance = AsyncMock()
        instance.get = AsyncMock(side_effect=_timeout_get)
        instance.__aenter__ = AsyncMock(return_value=instance)
        instance.__aexit__ = AsyncMock(return_value=False)
        MockClient.return_value = instance

        with patch(
            "hook_voice.hook_handlers._HUD_SNAPSHOT_PATH"
        ) as mock_path:
            mock_path.exists.return_value = True
            with patch(
                "hook_voice.hook_handlers.load_snapshot",
                return_value=snapshot,
            ), patch(
                "hook_voice.hook_handlers.build_label",
                return_value="🔊 focus [M2]",
            ):
                from hook_voice.hook_handlers import handle_hud_label
                await handle_hud_label()

    captured = capsys.readouterr()
    assert captured.err == ""
    data = json.loads(captured.out.strip())
    assert isinstance(data.get("label"), str)
    assert data["label"] == "🔊 focus [M2]"


async def test_api_timeout_no_snapshot_returns_offline(capsys):
    """API timeout + snapshot 파일 없음 → chorus offline 출력."""

    async def _timeout_get(url, timeout):
        raise httpx.TimeoutException("timeout")

    with patch("hook_voice.hook_handlers.httpx.AsyncClient") as MockClient:
        instance = AsyncMock()
        instance.get = AsyncMock(side_effect=_timeout_get)
        instance.__aenter__ = AsyncMock(return_value=instance)
        instance.__aexit__ = AsyncMock(return_value=False)
        MockClient.return_value = instance

        with patch(
            "hook_voice.hook_handlers._HUD_SNAPSHOT_PATH"
        ) as mock_path:
            mock_path.exists.return_value = False
            from hook_voice.hook_handlers import handle_hud_label
            await handle_hud_label()

    captured = capsys.readouterr()
    assert captured.err == ""
    data = json.loads(captured.out.strip())
    assert data == {"label": "chorus offline"}


async def test_output_is_parseable_json_with_string_label(capsys):
    """stdout은 항상 파싱 가능한 JSON이고 label 값은 string이다."""
    async def _timeout_get(url, timeout):
        raise httpx.TimeoutException("t")

    with patch("hook_voice.hook_handlers.httpx.AsyncClient") as MockClient:
        instance = AsyncMock()
        instance.get = AsyncMock(side_effect=_timeout_get)
        instance.__aenter__ = AsyncMock(return_value=instance)
        instance.__aexit__ = AsyncMock(return_value=False)
        MockClient.return_value = instance

        with patch(
            "hook_voice.hook_handlers._HUD_SNAPSHOT_PATH"
        ) as mock_path:
            mock_path.exists.return_value = False
            from hook_voice.hook_handlers import handle_hud_label
            await handle_hud_label()

    captured = capsys.readouterr()
    out = captured.out.strip()
    parsed = json.loads(out)
    assert isinstance(parsed, dict)
    assert "label" in parsed
    assert isinstance(parsed["label"], str)


# ── __main__ 디스패치 테스트 ─────────────────────────────────────────────────

async def _run_main(argv, stdin_data=""):
    with patch("sys.argv", argv):
        with patch("hook_voice.__main__._read_stdin", new=AsyncMock(return_value=stdin_data)):
            from hook_voice.__main__ import main
            await main()


async def test_hud_label_subcommand_dispatches():
    """hud-label 서브커맨드가 handle_hud_label을 호출한다."""
    with patch("hook_voice.__main__.handle_hud_label", new=AsyncMock()) as mock:
        await _run_main(["prog", "hud-label"])
        mock.assert_called_once_with()
