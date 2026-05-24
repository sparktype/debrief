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

    def test_meta_files_removed_with_audio(self, tmp_path):
        """오래된 오디오 파일 삭제 시 대응 .meta 파일도 함께 삭제된다."""
        from tts_server.supervisor import _do_cleanup

        old_wav = tmp_path / "1000.wav"
        old_wav.write_bytes(b"old")
        old_meta = tmp_path / "1000.meta"
        old_meta.write_text("1.2")
        old_time = time.time() - 360
        os.utime(str(old_wav), (old_time, old_time))
        os.utime(str(old_meta), (old_time, old_time))

        _do_cleanup(tmp_path)

        assert not old_wav.exists()
        assert not old_meta.exists()
