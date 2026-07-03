# HUD 스냅샷 저장 및 로드 모듈
"""chorus HUD 상태 스냅샷의 JSON 직렬화·역직렬화·레이블 생성."""
from __future__ import annotations

import json
import logging
import re
import tempfile
from pathlib import Path

_logger = logging.getLogger(__name__)

# 기본 스냅샷 저장 경로
_DEFAULT_SNAPSHOT_PATH: Path = Path.home() / ".local" / "share" / "chorus" / "hud.json"

# redact 기준: 30자 이상 영숫자+특수문자(연속)
_SECRET_PATTERN = re.compile(r'^[A-Za-z0-9!@#$%^&*()\-_=+\[\]{};:\'",.<>?/\\|`~]{30,}$')

# 기본 스냅샷 값
_SAFE_DEFAULTS: dict = {
    "mode": "normal",
    "voice": "F1",
    "auto_speak": True,
}


def _redact(value: object) -> object:
    """30자 이상 시크릿 패턴 문자열을 [REDACTED]로 치환한다."""
    if isinstance(value, str) and _SECRET_PATTERN.match(value):
        return "[REDACTED]"
    return value


def _redact_snapshot(snapshot: dict) -> dict:
    """스냅샷 딕셔너리의 모든 top-level 값을 redact 처리한다."""
    return {k: _redact(v) for k, v in snapshot.items()}


def load_snapshot(path: Path | None = None) -> dict:
    """스냅샷 JSON을 읽어 dict로 반환한다.

    파일이 없거나 파싱 실패 시 safe defaults를 반환하며 절대 raise하지 않는다.
    """
    target = path if path is not None else _DEFAULT_SNAPSHOT_PATH
    try:
        if not target.exists():
            return dict(_SAFE_DEFAULTS)
        text = target.read_text(encoding="utf-8")
        data = json.loads(text)
        if not isinstance(data, dict):
            _logger.warning("HUD 스냅샷 형식 오류, 기본값 사용: %s", target)
            return dict(_SAFE_DEFAULTS)
        # safe defaults로 기본 키 채우기
        result = dict(_SAFE_DEFAULTS)
        result.update(data)
        return result
    except json.JSONDecodeError as e:
        _logger.warning("HUD 스냅샷 JSON 파싱 실패, 기본값 사용: %s", e)
        return dict(_SAFE_DEFAULTS)
    except Exception as e:
        _logger.warning("HUD 스냅샷 로드 실패, 기본값 사용: %s", e)
        return dict(_SAFE_DEFAULTS)


def save_snapshot(snapshot: dict, path: Path | None = None) -> None:
    """스냅샷을 atomic write(임시 파일 → rename)로 저장한다.

    시크릿 패턴 값은 저장 전 redact하며, 실패 시 raise하지 않는다(best-effort).
    """
    target = path if path is not None else _DEFAULT_SNAPSHOT_PATH
    tmp_path: Path | None = None
    try:
        target.parent.mkdir(parents=True, exist_ok=True)
        redacted = _redact_snapshot(snapshot)
        payload = json.dumps(redacted, ensure_ascii=False, indent=2)
        # atomic: 임시 파일에 쓴 뒤 rename
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=target.parent,
            suffix=".tmp",
            delete=False,
        ) as tf:
            tmp_path = Path(tf.name)
            tf.write(payload)
        tmp_path.rename(target)
    except Exception as e:
        _logger.warning("HUD 스냅샷 저장 실패 (best-effort): %s", e)
        # 임시 파일 정리 시도
        try:
            if tmp_path is not None and tmp_path.exists():
                tmp_path.unlink(missing_ok=True)
        except Exception:
            pass


def build_label(snapshot: dict, max_chars: int = 50) -> str:
    """스냅샷에서 상태 표시줄용 레이블을 생성한다.

    항상 max_chars 이하의 문자열을 반환한다.
    """
    mode = snapshot.get("mode", "normal") or "normal"
    voice = snapshot.get("voice", "")
    auto_speak = snapshot.get("auto_speak", True)
    speak_icon = "🔊" if auto_speak else "🔇"

    parts = []
    if voice:
        parts.append(f"{speak_icon} {mode} [{voice}]")
    else:
        parts.append(f"{speak_icon} {mode}")

    label = " ".join(parts)
    # max_chars 초과 시 잘라냄
    if len(label) > max_chars:
        label = label[:max_chars]
    return label
