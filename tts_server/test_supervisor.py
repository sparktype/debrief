# tts_server supervisor 단위 테스트
import asyncio
import os
import time
from pathlib import Path


# mlx 없는 환경에서도 import 가능하도록 사전 stub
import sys
sys.modules.setdefault("mlx_audio", type(sys)("mlx_audio"))
sys.modules.setdefault("mlx_audio.tts", type(sys)("mlx_audio.tts"))
sys.modules.setdefault("mlx_audio.tts.generate", type(sys)("mlx_audio.tts.generate"))
sys.modules.setdefault("mlx_audio.tts.utils", type(sys)("mlx_audio.tts.utils"))


class TestDoCleanup:
    def test_old_files_removed(self, tmp_path):
        """5분 초과 오디오 파일은 삭제된다."""
        from tts_server.supervisor import _do_cleanup

        old = tmp_path / "1000.wav"
        old.write_bytes(b"old")
        old_time = time.time() - 360  # 6분 전
        os.utime(str(old), (old_time, old_time))

        fresh = tmp_path / "9999999.wav"
        fresh.write_bytes(b"fresh")

        _do_cleanup(tmp_path)

        assert not old.exists(), "6분 전 파일은 삭제되어야 한다"
        assert fresh.exists(), "최신 파일은 유지되어야 한다"

    def test_max_files_enforced(self, tmp_path):
        """파일이 10개 초과면 오래된 것부터 제거한다."""
        from tts_server.supervisor import _do_cleanup

        for i in range(12):
            (tmp_path / f"{1000 + i}.wav").write_bytes(b"x")

        _do_cleanup(tmp_path)

        remaining = list(tmp_path.glob("*.wav"))
        assert len(remaining) == 10, f"10개만 남아야 하는데 {len(remaining)}개"

    def test_old_audio_file_removed_no_meta(self, tmp_path):
        """오래된 오디오 파일은 삭제된다 — .meta 파일 없이 파일명에 speed 인코딩."""
        from tts_server.supervisor import _do_cleanup

        old_wav = tmp_path / "1000_120.wav"
        old_wav.write_bytes(b"old")
        old_time = time.time() - 360
        os.utime(str(old_wav), (old_time, old_time))

        _do_cleanup(tmp_path)

        assert not old_wav.exists()


class TestPlayerLoop:
    def test_plays_wav_with_default_speed(self, tmp_path):
        """파일명에 speed 태그 없으면 기본값 1.0으로 afplay 호출한다."""
        from unittest.mock import AsyncMock, patch

        audio = tmp_path / "1000.wav"
        audio.write_bytes(b"audio")

        played = []
        shutdown = asyncio.Event()

        async def fake_exec(*args, **kwargs):
            played.append(args)
            shutdown.set()  # 1회 재생 후 종료
            mock = AsyncMock()
            mock.wait = AsyncMock(return_value=0)
            return mock

        async def run():
            with patch("tts_server.supervisor.asyncio.create_subprocess_exec", side_effect=fake_exec):
                from tts_server.supervisor import player_loop
                await player_loop(spool=tmp_path, shutdown=shutdown)

        asyncio.run(run())
        assert len(played) == 1
        assert played[0] == ("afplay", "-r", "1.0", str(audio))

    def test_reads_speed_from_filename(self, tmp_path):
        """파일명에 인코딩된 speed를 파싱해 afplay에 전달한다."""
        from unittest.mock import AsyncMock, patch

        audio = tmp_path / "2000_abc12_150.wav"
        audio.write_bytes(b"audio")

        played = []
        shutdown = asyncio.Event()

        async def fake_exec(*args, **kwargs):
            played.append(args)
            shutdown.set()
            mock = AsyncMock()
            mock.wait = AsyncMock(return_value=0)
            return mock

        async def run():
            with patch("tts_server.supervisor.asyncio.create_subprocess_exec", side_effect=fake_exec):
                from tts_server.supervisor import player_loop
                await player_loop(spool=tmp_path, shutdown=shutdown)

        asyncio.run(run())
        assert played[0][2] == "1.5"

    def test_deletes_audio_after_play(self, tmp_path):
        """재생 완료 후 오디오 파일이 삭제된다."""
        from unittest.mock import AsyncMock, patch

        audio = tmp_path / "3000.mp3"
        audio.write_bytes(b"audio")

        shutdown = asyncio.Event()

        async def fake_exec(*args, **kwargs):
            shutdown.set()
            mock = AsyncMock()
            mock.wait = AsyncMock(return_value=0)
            return mock

        async def run():
            with patch("tts_server.supervisor.asyncio.create_subprocess_exec", side_effect=fake_exec):
                from tts_server.supervisor import player_loop
                await player_loop(spool=tmp_path, shutdown=shutdown)

        asyncio.run(run())
        assert not audio.exists(), "재생 후 파일이 삭제되어야 한다"

    def test_epoch_ascending_order(self, tmp_path):
        """여러 파일이 있으면 epoch_ms 오름차순(가장 오래된 것) 먼저 재생한다."""
        from unittest.mock import AsyncMock, patch

        (tmp_path / "9000.wav").write_bytes(b"later")
        (tmp_path / "1000.wav").write_bytes(b"earlier")

        played = []
        call_count = 0
        shutdown = asyncio.Event()

        async def fake_exec(*args, **kwargs):
            nonlocal call_count
            played.append(Path(args[-1]).name)
            call_count += 1
            if call_count >= 2:
                shutdown.set()
            mock = AsyncMock()
            mock.wait = AsyncMock(return_value=0)
            return mock

        async def run():
            with patch("tts_server.supervisor.asyncio.create_subprocess_exec", side_effect=fake_exec):
                from tts_server.supervisor import player_loop
                await player_loop(spool=tmp_path, shutdown=shutdown)

        asyncio.run(run())
        assert played[0] == "1000.wav", "오래된 파일이 먼저 재생되어야 한다"


class TestMonitorChildren:
    def test_sets_shutdown_on_child_exit(self):
        """자식 프로세스가 종료되면 shutdown 이벤트를 set한다."""
        from unittest.mock import MagicMock
        from tts_server.supervisor import monitor_children

        proc = MagicMock()
        proc.pid = 9999
        proc.poll.return_value = 1  # 비정상 종료

        shutdown = asyncio.Event()

        async def run():
            await monitor_children([proc], shutdown=shutdown, sleep_sec=0.01)

        asyncio.run(run())
        assert shutdown.is_set(), "자식 종료 시 shutdown 이벤트가 set되어야 한다"

    def test_does_not_shutdown_while_children_running(self):
        """자식이 정상 실행 중이면 shutdown을 set하지 않는다."""
        from unittest.mock import MagicMock
        from tts_server.supervisor import monitor_children

        proc = MagicMock()
        proc.pid = 9998
        proc.poll.return_value = None  # 실행 중

        shutdown = asyncio.Event()
        # call_count를 외부에서 참조할 수 있도록 리스트로 래핑
        counter = [0]

        async def run():
            def patched_poll():
                counter[0] += 1
                if counter[0] >= 3:
                    shutdown.set()
                return None

            proc.poll = patched_poll
            await monitor_children([proc], shutdown=shutdown, sleep_sec=0.01)

        asyncio.run(run())
        assert counter[0] >= 3
