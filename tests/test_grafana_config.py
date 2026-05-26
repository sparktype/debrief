# Grafana 설정 섹션 로딩 및 기본값 검증 테스트
import json
import pytest
from hook_voice.config import Config, GrafanaConfig, load_config


def test_grafana_config_defaults():
    config = Config()
    assert config.grafana.enabled is False
    assert config.grafana.url == ""
    assert config.grafana.token == ""
    assert config.grafana.interval == 30
    assert config.grafana.alerts == []


def test_load_config_grafana_section(tmp_path):
    cfg = tmp_path / "persona.json"
    cfg.write_text(json.dumps({
        "grafana": {
            "enabled": True,
            "url": "http://grafana.internal:3000",
            "token": "glsa_test",
            "interval": 60,
            "alerts": ["Kafka Consumer Lag", "Spark Job Failed"],
        }
    }), encoding="utf-8")
    config = load_config(cfg)
    assert config.grafana.enabled is True
    assert config.grafana.url == "http://grafana.internal:3000"
    assert config.grafana.token == "glsa_test"
    assert config.grafana.interval == 60
    assert config.grafana.alerts == ["Kafka Consumer Lag", "Spark Job Failed"]


def test_load_config_grafana_partial(tmp_path):
    cfg = tmp_path / "persona.json"
    cfg.write_text(json.dumps({"grafana": {"enabled": True}}), encoding="utf-8")
    config = load_config(cfg)
    assert config.grafana.enabled is True
    assert config.grafana.interval == 30  # 기본값 유지


def test_load_config_without_grafana(tmp_path):
    cfg = tmp_path / "persona.json"
    cfg.write_text(json.dumps({"voice": "Sohee"}), encoding="utf-8")
    config = load_config(cfg)
    assert config.grafana.enabled is False
    assert config.voice == "Sohee"
