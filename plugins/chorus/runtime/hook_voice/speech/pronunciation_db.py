# hook_voice/speech/pronunciation_db.py — Trie + LRU 기반 IT 용어 발음 사전
from __future__ import annotations

from collections import OrderedDict
from typing import NamedTuple


class PronunciationEntry(NamedTuple):
    reading: str       # 한국어 발음 (예: "에이피아이")
    ssml_alias: str    # SSML <sub alias=""> 값 (reading과 동일하거나 음소 표기)
    prosody_rate: str  # "slow" | "medium" | "fast" (발음 속도 힌트)


class _TrieNode:
    __slots__ = ("children", "entry")

    def __init__(self) -> None:
        self.children: dict[str, "_TrieNode"] = {}
        self.entry: PronunciationEntry | None = None


class PronunciationTrie:
    """대소문자 무시 접두사 매칭 Trie. 가장 긴 매칭 우선."""

    def __init__(self) -> None:
        self._root = _TrieNode()

    def insert(self, term: str, entry: PronunciationEntry) -> None:
        node = self._root
        for ch in term.upper():
            node = node.children.setdefault(ch, _TrieNode())
        node.entry = entry

    def longest_match(self, text: str, start: int) -> tuple[int, PronunciationEntry] | None:
        """text[start:]에서 가장 긴 매칭 반환. (end_index, entry) 또는 None."""
        node = self._root
        last_match: tuple[int, PronunciationEntry] | None = None
        i = start
        upper = text.upper()
        while i < len(upper):
            ch = upper[i]
            if ch not in node.children:
                break
            node = node.children[ch]
            if node.entry is not None:
                last_match = (i + 1, node.entry)
            i += 1
        return last_match


class LRUCache:
    """최대 maxsize 항목을 보관하는 LRU 캐시."""

    def __init__(self, maxsize: int = 10_000) -> None:
        self._maxsize = maxsize
        self._cache: OrderedDict[str, str] = OrderedDict()

    def get(self, key: str) -> str | None:
        if key not in self._cache:
            return None
        self._cache.move_to_end(key)
        return self._cache[key]

    def set(self, key: str, value: str) -> None:
        if key in self._cache:
            self._cache.move_to_end(key)
        self._cache[key] = value
        if len(self._cache) > self._maxsize:
            self._cache.popitem(last=False)

    def __len__(self) -> int:
        return len(self._cache)


# ── 200개 IT 용어 마스터 사전 ────────────────────────────────────────────────

def _e(reading: str, prosody: str = "medium") -> PronunciationEntry:
    return PronunciationEntry(reading=reading, ssml_alias=reading, prosody_rate=prosody)


_IT_TERMS: dict[str, PronunciationEntry] = {
    # 프로토콜·표준
    "API": _e("에이피아이"),
    "REST": _e("레스트"),
    "RESTFUL": _e("레스트풀"),
    "GRAPHQL": _e("그래프큐엘"),
    "GRPC": _e("지알피씨"),
    "HTTP": _e("에이치티티피"),
    "HTTPS": _e("에이치티티피에스"),
    "MQTT": _e("엠큐티티"),
    "TCP": _e("티씨피"),
    "UDP": _e("유디피"),
    "IP": _e("아이피"),
    "DNS": _e("디엔에스"),
    "TLS": _e("티엘에스"),
    "SSL": _e("에스에스엘"),
    "SSH": _e("에스에스에이치"),
    "FTP": _e("에프티피"),
    "SMTP": _e("에스엠티피"),
    "IMAP": _e("아이맵"),
    "POP3": _e("팝쓰리"),
    "AMQP": _e("에이엠큐피"),
    "STOMP": _e("스탐프"),
    "WEBSOCKET": _e("웹소켓"),
    "SSE": _e("에스에스이"),
    "CORS": _e("코스"),
    "CSRF": _e("씨에스알에프"),
    "XSS": _e("엑스에스에스"),
    "JWT": _e("제이더블유티"),
    "OAUTH": _e("오어스"),
    "SAML": _e("새믈"),
    "LDAP": _e("엘댑"),

    # 하드웨어·시스템
    "GPU": _e("지피유"),
    "CPU": _e("씨피유"),
    "TPU": _e("티피유"),
    "NPU": _e("엔피유"),
    "SSD": _e("에스에스디"),
    "HDD": _e("에이치디디"),
    "RAM": _e("램"),
    "ROM": _e("롬"),
    "USB": _e("유에스비"),
    "HDMI": _e("에이치디엠아이"),
    "PCIe": _e("피씨아이익스프레스"),
    "NVME": _e("엔브이엠이"),

    # AI·ML
    "LLM": _e("엘엘엠"),
    "GPT": _e("지피티"),
    "RAG": _e("래그"),
    "RLHF": _e("알엘에이치에프"),
    "CNN": _e("씨엔엔"),
    "RNN": _e("알엔엔"),
    "LSTM": _e("엘에스티엠"),
    "GAN": _e("갠"),
    "VAE": _e("브이에이이"),
    "NLP": _e("엔엘피"),
    "NLU": _e("엔엘유"),
    "NLG": _e("엔엘지"),
    "OCR": _e("오씨알"),
    "ASR": _e("에이에스알"),
    "TTS": _e("티티에스"),
    "STT": _e("에스티티"),
    "BERT": _e("버트"),
    "MLP": _e("엠엘피"),
    "MLX": _e("엠엘엑스"),

    # 클라우드·인프라
    "AWS": _e("에이더블유에스"),
    "GCP": _e("지씨피"),
    "GKE": _e("지케이이"),
    "EKS": _e("이케이에스"),
    "AKS": _e("에이케이에스"),
    "S3": _e("에스쓰리"),
    "EC2": _e("이씨투"),
    "VPC": _e("브이피씨"),
    "IAM": _e("아이에이엠"),
    "CDN": _e("씨디엔"),
    "K8S": _e("쿠버네티스"),
    "K3S": _e("케이쓰리에스"),
    "KEDA": _e("케다"),
    "HELM": _e("헬름"),
    "ISTIO": _e("이스티오"),
    "ELB": _e("이엘비"),
    "ALB": _e("에이엘비"),
    "NLB": _e("엔엘비"),
    "RDS": _e("알디에스"),
    "DynamoDB": _e("다이나모디비"),

    # 데이터베이스
    "SQL": _e("에스큐엘"),
    "NoSQL": _e("노에스큐엘"),
    "RDBMS": _e("알디비엠에스"),
    "ORM": _e("오알엠"),
    "DDL": _e("디디엘"),
    "DML": _e("디엠엘"),
    "OLAP": _e("올랩"),
    "OLTP": _e("올티피"),
    "ETL": _e("이티엘"),
    "ELT": _e("이엘티"),
    "Kafka": _e("카프카"),
    "Redis": _e("레디스"),
    "MongoDB": _e("몽고디비"),
    "PostgreSQL": _e("포스트그레에스큐엘"),
    "MySQL": _e("마이에스큐엘"),
    "SQLite": _e("에스큐엘라이트"),

    # 개발 도구·언어
    "CLI": _e("씨엘아이"),
    "SDK": _e("에스디케이"),
    "IDE": _e("아이디이"),
    "VIM": _e("빔"),
    "VSCode": _e("브이에스코드"),
    "GIT": _e("깃"),
    "CI": _e("씨아이"),
    "CD": _e("씨디"),
    "CICD": _e("씨아이씨디"),
    "CI/CD": _e("씨아이씨디"),
    "PR": _e("피알"),
    "MR": _e("엠알"),
    "YAML": _e("야믈"),
    "TOML": _e("톰엘"),
    "JSON": _e("제이슨"),
    "XML": _e("엑스엠엘"),
    "CSV": _e("씨에스브이"),
    "HTML": _e("에이치티엠엘"),
    "CSS": _e("씨에스에스"),
    "DOM": _e("돔"),
    "npm": _e("엔피엠"),
    "uv": _e("유브이"),
    "pip": _e("핍"),
    "PyPI": _e("파이파이"),

    # 아키텍처 패턴
    "MVC": _e("엠브이씨"),
    "MVP": _e("엠브이피"),
    "MVVM": _e("엠브이브이엠"),
    "DDD": _e("디디디"),
    "TDD": _e("티디디"),
    "BDD": _e("비디디"),
    "CQRS": _e("씨큐알에스"),
    "MSA": _e("엠에스에이"),
    "SOA": _e("에스오에이"),
    "EDA": _e("이디에이"),
    "DLQ": _e("디엘큐"),
    "HWM": _e("에이치더블유엠"),
    "LWM": _e("엘더블유엠"),

    # 관찰 가능성
    "OTel": _e("오텔"),
    "APM": _e("에이피엠"),
    "SLO": _e("에스엘오"),
    "SLA": _e("에스엘에이"),
    "SLI": _e("에스엘아이"),
    "MTTR": _e("엠티티알"),
    "MTTF": _e("엠티티에프"),
    "P50": _e("피오십"),
    "P95": _e("피구십오"),
    "P99": _e("피구십구"),
    "EPS": _e("이피에스"),
    "QPS": _e("큐피에스"),
    "RPS": _e("알피에스"),
    "TPS": _e("티피에스"),

    # 보안
    "OWASP": _e("오왑"),
    "CVE": _e("씨브이이"),
    "XSS": _e("엑스에스에스"),
    "SSRF": _e("에스에스알에프"),
    "RCE": _e("알씨이"),
    "DoS": _e("디오에스"),
    "DDoS": _e("디디오에스"),
    "WAF": _e("와프"),
    "VPN": _e("브이피엔"),
    "MFA": _e("엠에프에이"),
    "SSO": _e("에스에스오"),
    "PEM": _e("피이엠"),
    "AES": _e("에이이에스"),
    "RSA": _e("알에스에이"),

    # 스크린·미디어
    "FPS": _e("에프피에스"),
    "4K": _e("포케이"),
    "8K": _e("팔케이"),
    "HDR": _e("에이치디알"),
    "UHD": _e("유에이치디"),

    # 에이전트·LLM 도구
    "MCP": _e("엠씨피"),
    "RAG": _e("래그"),
    "REPL": _e("레플"),
    "JSONL": _e("제이슨엘"),
    "Webhook": _e("웹훅"),
    "EOF": _e("이오에프"),
    "STDIN": _e("스탠다드인"),
    "STDOUT": _e("스탠다드아웃"),
    "STDERR": _e("스탠다드에러"),
    "PID": _e("피아이디"),
    "UUID": _e("유유아이디"),
    "MD5": _e("엠디파이브"),
    "SHA256": _e("샤이투오십육"),

    # 파일·경로
    "README": _e("리드미"),
    "CHANGELOG": _e("체인지로그"),
    "Dockerfile": _e("도커파일"),
    "Makefile": _e("메이크파일"),

    # 기타 흔한 약어
    "ETA": _e("이티에이"),
    "MVP": _e("엠브이피"),
    "POC": _e("피오씨"),
    "EOL": _e("이오엘"),
    "EOD": _e("이오디"),
    "EOY": _e("이오와이"),
    "FAQ": _e("에프에이큐"),
    "TBD": _e("티비디"),
    "TBD": _e("티비디"),
    "AFAIK": _e("아파익"),
    "LGTM": _e("엘지티엠"),
    "WIP": _e("윕"),
    "IIUC": _e("아이유씨"),
    "IIRC": _e("아이알씨"),
}


class PronunciationDB:
    """Trie 조회 + LRU 캐시로 구성된 발음 사전."""

    def __init__(self, maxsize: int = 10_000) -> None:
        self._trie = PronunciationTrie()
        self._cache: LRUCache = LRUCache(maxsize)
        for term, entry in _IT_TERMS.items():
            self._trie.insert(term, entry)

    def apply(self, text: str) -> str:
        """텍스트에서 IT 용어를 찾아 한국어 발음으로 치환한다."""
        cached = self._cache.get(text)
        if cached is not None:
            return cached

        result: list[str] = []
        i = 0
        while i < len(text):
            match = self._trie.longest_match(text, i)
            if match is not None:
                end, entry = match
                # 단어 경계 확인 — 앞뒤가 ASCII 영문자면 매칭 제외 (한국어는 경계로 허용)
                before_ok = i == 0 or not (text[i - 1].isascii() and text[i - 1].isalpha())
                after_ok = end >= len(text) or not (text[end].isascii() and text[end].isalpha())
                if before_ok and after_ok:
                    result.append(entry.reading)
                    i = end
                    continue
            result.append(text[i])
            i += 1

        out = "".join(result)
        self._cache.set(text, out)
        return out

    def add(self, term: str, reading: str, prosody: str = "medium") -> None:
        """런타임에 사전 항목 추가."""
        entry = PronunciationEntry(reading=reading, ssml_alias=reading, prosody_rate=prosody)
        self._trie.insert(term, entry)


# 모듈 싱글톤 — 전역 재사용
_default_db: PronunciationDB | None = None


def get_default_db() -> PronunciationDB:
    global _default_db
    if _default_db is None:
        _default_db = PronunciationDB()
    return _default_db
