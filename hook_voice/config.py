# hook_voice/config.py
# 사용자 설정 파일 로더 및 기본값 관리
import json
import logging
from dataclasses import dataclass, field
from pathlib import Path

_logger = logging.getLogger(__name__)

_VOICE_JSON = Path(__file__).parent.parent / ".voice.json"
_VOICE_PERSONA_JSON = Path(__file__).parent.parent / ".voice-persona.json"

_KEY_MAP = {
    "autoSpeak": "auto_speak",
    "minChars": "min_chars",
    "voice": "voice",
    "summaryModel": "summary_model",
    "ttsSpeed": "tts_speed",
    "ttsInstruct": "tts_instruct",
    "skillCooldownMinutes": "skill_cooldown_minutes",
    "supertonicPort": "supertonic_port",
    "supertonicTimeoutMs": "supertonic_timeout_ms",
    "allowInsecureTls": "allow_insecure_tls",
    "speechRetouch": "speech_retouch",
    "bridgeEnabled": "bridge_enabled",
    "bridgeThresholdMs": "bridge_threshold_ms",
    "resumeThreshold": "resume_threshold",
    "usageTracking": "usage_tracking",
    "voiceMode": "voice_mode",
}


@dataclass
class GrafanaConfig:
    enabled: bool = False
    url: str = ""
    token: str = ""
    interval: int = 30
    alerts: list[str] = field(default_factory=list)


@dataclass
class SttConfig:
    enabled: bool = False
    model: str = "mlx-community/whisper-small-mlx"
    language: str = "ko"
    sample_rate: int = 16000
    announce: bool = True
    vad_interrupt: bool = False


@dataclass
class Config:
    auto_speak: bool = True
    min_chars: int = 50
    voice: str = "Sohee"
    summary_model: str = "gemini-3.5-flash"
    tts_speed: float = 1.1
    tts_instruct: str = "밝고 활기차게 말해주세요"
    skill_cooldown_minutes: int = 30
    supertonic_port: int = 7777
    supertonic_timeout_ms: int = 20000
    allow_insecure_tls: bool = True
    speech_retouch: bool = True
    bridge_enabled: bool = False
    bridge_threshold_ms: int = 500
    resume_threshold: float = 0.0  # 0.0 = 항상 포기, 0.85 = 85% 이상 완료 시 계속
    usage_tracking: bool = True
    voice_mode: str = "normal"
    grafana: GrafanaConfig = field(default_factory=GrafanaConfig)
    stt: SttConfig = field(default_factory=SttConfig)


def _warn_invalid(key: str, value: object, fallback: object) -> None:
    _logger.warning(".voice.json 잘못된 값: %s=%r, 기본값 %r 사용", key, value, fallback)


def _normalize_config(kwargs: dict[str, object]) -> dict[str, object]:
    defaults = Config()

    def _normalize_int(key: str, minimum: int, maximum: int | None = None) -> None:
        if key not in kwargs:
            return
        value = kwargs[key]
        if isinstance(value, bool) or not isinstance(value, int) or value < minimum or (maximum is not None and value > maximum):
            _warn_invalid(key, value, getattr(defaults, key))
            kwargs[key] = getattr(defaults, key)

    def _normalize_float(key: str, minimum: float) -> None:
        if key not in kwargs:
            return
        value = kwargs[key]
        if not isinstance(value, (int, float)) or float(value) <= minimum:
            _warn_invalid(key, value, getattr(defaults, key))
            kwargs[key] = getattr(defaults, key)
        else:
            kwargs[key] = float(value)

    def _normalize_bool(key: str) -> None:
        if key not in kwargs:
            return
        value = kwargs[key]
        if not isinstance(value, bool):
            _warn_invalid(key, value, getattr(defaults, key))
            kwargs[key] = getattr(defaults, key)

    def _normalize_str(key: str) -> None:
        if key not in kwargs:
            return
        value = kwargs[key]
        if not isinstance(value, str) or not value.strip():
            _warn_invalid(key, value, getattr(defaults, key))
            kwargs[key] = getattr(defaults, key)
        else:
            kwargs[key] = value.strip()

    _normalize_bool("auto_speak")
    _normalize_bool("allow_insecure_tls")
    _normalize_bool("speech_retouch")
    _normalize_bool("bridge_enabled")
    _normalize_bool("usage_tracking")
    _normalize_int("min_chars", 0)
    _normalize_int("bridge_threshold_ms", 0)
    _normalize_float("tts_speed", 0.0)
    _normalize_float("resume_threshold", -0.1)
    _normalize_str("voice_mode")
    _normalize_int("skill_cooldown_minutes", 0)
    _normalize_int("supertonic_port", 1, 65535)
    _normalize_int("supertonic_timeout_ms", 100)

    grafana = kwargs.get("grafana")
    if isinstance(grafana, GrafanaConfig):
        if grafana.interval < 5:
            _warn_invalid("grafana.interval", grafana.interval, defaults.grafana.interval)
            grafana.interval = defaults.grafana.interval
        if not isinstance(grafana.alerts, list) or not all(isinstance(a, str) for a in grafana.alerts):
            _warn_invalid("grafana.alerts", grafana.alerts, defaults.grafana.alerts)
            grafana.alerts = defaults.grafana.alerts

    stt = kwargs.get("stt")
    if isinstance(stt, SttConfig):
        if not isinstance(stt.enabled, bool):
            _warn_invalid("stt.enabled", stt.enabled, defaults.stt.enabled)
            stt.enabled = defaults.stt.enabled
        if not isinstance(stt.announce, bool):
            _warn_invalid("stt.announce", stt.announce, defaults.stt.announce)
            stt.announce = defaults.stt.announce
        if not isinstance(stt.model, str) or not stt.model:
            _warn_invalid("stt.model", stt.model, defaults.stt.model)
            stt.model = defaults.stt.model
        if not isinstance(stt.language, str) or not stt.language:
            _warn_invalid("stt.language", stt.language, defaults.stt.language)
            stt.language = defaults.stt.language
        if not isinstance(stt.sample_rate, int) or isinstance(stt.sample_rate, bool) or stt.sample_rate <= 0:
            _warn_invalid("stt.sample_rate", stt.sample_rate, defaults.stt.sample_rate)
            stt.sample_rate = defaults.stt.sample_rate
        if not isinstance(stt.vad_interrupt, bool):
            _warn_invalid("stt.vad_interrupt", stt.vad_interrupt, defaults.stt.vad_interrupt)
            stt.vad_interrupt = defaults.stt.vad_interrupt

    return kwargs


def _find_default_config() -> Path | None:
    if _VOICE_JSON.exists():
        return _VOICE_JSON
    if _VOICE_PERSONA_JSON.exists():
        return _VOICE_PERSONA_JSON
    return None


def load_config(path: Path | None = None) -> Config:
    target = path or _find_default_config()
    if target is None or not target.exists():
        return Config()
    try:
        data = json.loads(target.read_text(encoding="utf-8"))
        kwargs = {py_k: data[json_k] for json_k, py_k in _KEY_MAP.items() if json_k in data}
        if "grafana" in data:
            g = data["grafana"]
            kwargs["grafana"] = GrafanaConfig(
                enabled=g.get("enabled", False),
                url=g.get("url", ""),
                token=g.get("token", ""),
                interval=g.get("interval", 30),
                alerts=g.get("alerts", []),
            )
        if "stt" in data:
            s = data["stt"]
            kwargs["stt"] = SttConfig(
                enabled=s.get("enabled", False),
                model=s.get("model", "mlx-community/whisper-small-mlx"),
                language=s.get("language", "ko"),
                sample_rate=s.get("sampleRate", 16000),
                announce=s.get("announce", True),
                vad_interrupt=s.get("vadInterrupt", False),
            )
        kwargs = _normalize_config(kwargs)
        return Config(**kwargs)
    except json.JSONDecodeError as e:
        _logger.warning(".voice.json 파싱 실패, 기본값 사용: %s", e)
        return Config()
    except Exception as e:
        _logger.warning(".voice.json 로드 실패, 기본값 사용: %s", e)
        return Config()
