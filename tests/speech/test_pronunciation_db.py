# tests/speech/test_pronunciation_db.py — PronunciationDB 단위 테스트
import time
import pytest

from hook_voice.speech.pronunciation_db import (
    PronunciationDB,
    PronunciationTrie,
    LRUCache,
    get_default_db,
)


class TestLRUCache:
    def test_basic_set_get(self):
        c = LRUCache(maxsize=3)
        c.set("a", "1")
        assert c.get("a") == "1"

    def test_miss_returns_none(self):
        c = LRUCache()
        assert c.get("missing") is None

    def test_eviction(self):
        c = LRUCache(maxsize=2)
        c.set("a", "1")
        c.set("b", "2")
        c.set("c", "3")  # "a" evicted
        assert c.get("a") is None
        assert c.get("b") == "2"
        assert c.get("c") == "3"

    def test_access_updates_order(self):
        c = LRUCache(maxsize=2)
        c.set("a", "1")
        c.set("b", "2")
        c.get("a")       # "a" becomes most recent
        c.set("c", "3")  # "b" evicted (not "a")
        assert c.get("a") == "1"
        assert c.get("b") is None

    def test_len(self):
        c = LRUCache(maxsize=10)
        c.set("x", "1")
        c.set("y", "2")
        assert len(c) == 2


class TestPronunciationTrie:
    def test_single_term(self):
        from hook_voice.speech.pronunciation_db import PronunciationEntry, PronunciationTrie
        trie = PronunciationTrie()
        entry = PronunciationEntry("에이피아이", "에이피아이", "medium")
        trie.insert("API", entry)
        match = trie.longest_match("API 호출", 0)
        assert match is not None
        assert match[0] == 3
        assert match[1].reading == "에이피아이"

    def test_no_match(self):
        from hook_voice.speech.pronunciation_db import PronunciationTrie
        trie = PronunciationTrie()
        assert trie.longest_match("안녕하세요", 0) is None

    def test_longest_match_wins(self):
        from hook_voice.speech.pronunciation_db import PronunciationEntry, PronunciationTrie
        trie = PronunciationTrie()
        trie.insert("CI", PronunciationEntry("씨아이", "씨아이", "medium"))
        trie.insert("CI/CD", PronunciationEntry("씨아이씨디", "씨아이씨디", "medium"))
        match = trie.longest_match("CI/CD pipeline", 0)
        assert match is not None
        assert match[1].reading == "씨아이씨디"


class TestPronunciationDB:
    def test_api_replacement(self):
        db = PronunciationDB()
        result = db.apply("API 호출이 완료됐습니다.")
        assert "에이피아이" in result
        assert "API" not in result

    def test_gpu_replacement(self):
        db = PronunciationDB()
        result = db.apply("GPU 메모리가 부족합니다.")
        assert "지피유" in result

    def test_no_partial_match(self):
        db = PronunciationDB()
        # "APIS" — 단어 경계가 아니므로 치환 안 됨
        result = db.apply("APIS 는 복수형입니다")
        assert "에이피아이" not in result

    def test_ci_cd(self):
        db = PronunciationDB()
        result = db.apply("CI/CD 파이프라인")
        assert "씨아이씨디" in result

    def test_cache_hit(self):
        db = PronunciationDB()
        text = "LLM 기반 요약"
        db.apply(text)
        result2 = db.apply(text)  # cache hit
        assert "엘엘엠" in result2

    def test_add_custom_term(self):
        db = PronunciationDB()
        db.add("MYTERM", "마이텀")
        result = db.apply("MYTERM 테스트")
        assert "마이텀" in result

    def test_performance(self):
        db = PronunciationDB()
        text = "API GPU LLM HTTP CI/CD 파이프라인에서 작업이 완료됐습니다."
        start = time.perf_counter()
        for _ in range(100):
            db.apply(text)
        elapsed = time.perf_counter() - start
        assert elapsed < 0.1  # 100회에 0.1초 이하

    def test_default_db_singleton(self):
        db1 = get_default_db()
        db2 = get_default_db()
        assert db1 is db2

    def test_mixed_text(self):
        db = PronunciationDB()
        result = db.apply("오늘 API와 HTTP를 사용했습니다.")
        assert "에이피아이" in result
        assert "에이치티티피" in result
