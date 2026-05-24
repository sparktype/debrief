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
