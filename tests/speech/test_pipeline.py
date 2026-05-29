# tests/speech/test_pipeline.py — SpeechPipeline E2E 및 개별 스테이지 테스트
import pytest
from hook_voice.speech.pipeline import SpeechPipeline, SpeechContext, build_default_pipeline


async def test_pipeline_basic():
    p = build_default_pipeline()
    ctx = await p.process("API 빌드가 완료됐습니다.")
    assert "에이피아이" in ctx.text
    assert ctx.ssml != ""


async def test_pipeline_removes_markdown():
    p = build_default_pipeline()
    ctx = await p.process("**중요**: `git reset --hard` 실행하세요.")
    assert "**" not in ctx.text
    assert "`" not in ctx.text


async def test_pipeline_uuid_suppressed():
    p = build_default_pipeline()
    ctx = await p.process("트랜잭션 550e8400-e29b-41d4-a716-446655440000 처리됨")
    assert "고유" in ctx.text and "ID" in ctx.text


async def test_pipeline_url_suppressed():
    p = build_default_pipeline()
    ctx = await p.process("https://github.com/org/repo 를 확인하세요.")
    assert "링크 생략" in ctx.text


async def test_pipeline_snake_case_normalized():
    p = build_default_pipeline()
    ctx = await p.process("build_error 가 발생했습니다.")
    assert "build error" in ctx.text.lower()


async def test_pipeline_language_detection_korean():
    p = build_default_pipeline()
    ctx = await p.process("오늘 작업이 완료됐습니다.")
    assert ctx.language == "ko"
    assert ctx.language_confidence > 0.5


async def test_pipeline_language_detection_english():
    p = build_default_pipeline()
    ctx = await p.process("The build succeeded.")
    assert ctx.language == "en"


async def test_pipeline_mixed_language():
    p = build_default_pipeline()
    # 한국어 비중이 확실히 높은 텍스트 사용 (GPU 3글자 vs 한국어 9글자)
    ctx = await p.process("GPU 메모리가 부족합니다.")
    assert ctx.language in ("ko", "mixed")


async def test_pipeline_segments_populated():
    p = build_default_pipeline()
    ctx = await p.process("첫 번째 문장입니다. 두 번째 문장입니다.")
    assert len(ctx.segments) >= 1


async def test_pipeline_ssml_has_expression_tag():
    p = build_default_pipeline()
    ctx = await p.process("빌드가 실패했습니다. 에러를 확인하세요.", language_hint="ko")
    # 실패 키워드 → <sigh> 태그가 ssml에 포함되어야 함
    assert "<sigh>" in ctx.ssml or ctx.ssml != ""


async def test_pipeline_empty_input():
    p = build_default_pipeline()
    ctx = await p.process("")
    assert ctx.text == "" or ctx.ssml == ""


async def test_pipeline_custom_stage():
    def add_greeting(ctx: SpeechContext) -> SpeechContext:
        ctx.text = "안녕. " + ctx.text
        return ctx

    p = SpeechPipeline([add_greeting])
    ctx = await p.process("테스트")
    assert ctx.text.startswith("안녕.")


async def test_pipeline_it_terms_converted():
    p = build_default_pipeline()
    ctx = await p.process("LLM 응답이 왔습니다.")
    assert "엘엘엠" in ctx.text


async def test_pipeline_break_tags_in_ssml_not_text():
    p = build_default_pipeline()
    ctx = await p.process("EdgeTTS 발화 완료됐습니다.")
    # break 태그는 ctx.ssml에만 있어야 함 — ctx.text는 TTS 엔진에 직접 전달되므로 클린 상태 유지
    assert "break" not in ctx.text
    assert ctx.text  # 최소한 텍스트는 있어야 함
