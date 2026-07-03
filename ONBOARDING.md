# Welcome to 개발생산성본부

## How We Use Claude

Based on 박상선 책임매니저's usage over the last 30 days:

Work Type Breakdown:
  Write Docs      ████████░░░░░░░░░░░░  40%
  Plan Design     ███████░░░░░░░░░░░░░  35%
  Improve Quality █████░░░░░░░░░░░░░░░  25%

Top Skills & Commands:
  _(usage data not yet recorded — check back after a few sessions)_

Top MCP Servers:
  _(usage data not yet recorded — check back after a few sessions)_

## Your Setup Checklist

### Codebases
- [ ] chorus — github.com/sparktype/chorus

### MCP Servers to Activate
  _(none recorded in the last 30 days)_

### Skills to Know About
  _(none recorded yet — ask your teammate which skills they reach for most)_

## chorus 시스템 개요

chorus는 Claude Code 응답을 자동으로 음성으로 읽어주는 hook 기반 시스템입니다.  
아래 네 가지 기능이 서로 다른 역할을 담당합니다.

### TTS (음성 출력)

Claude Code가 응답을 완료하면 자동으로 요약해서 음성으로 읽어줍니다.  
서브에이전트 팀 작업 시 에이전트마다 다른 목소리가 배정됩니다.

**TTS로 발화되는 내용**:
- Stop hook: Claude 응답 브리핑 (결론·변경 파일·검증·다음 단계)
- PostToolUse Bash 실패: 실패 원인과 다음 단계 1~2문장
- PreToolUse Bash 위험 명령: 실행 전 1문장 경고
- 서브에이전트 완료: `"리뷰어 빌입니다. [한 줄 요약]"` 형식 보고

**TTS로 발화되지 않는 내용**:
- HUD 레이블 (`🔊 normal [F1]`) — statusline에만 표시, 소리 없음
- voiceMode 추천 이유 — 추천 안내는 발화하지만 설정을 자동 변경하지 않음

### HUD (상태 표시)

Claude Code statusline에 TTS 현재 상태를 표시합니다.  
HUD는 로컬 파일(`~/.local/share/chorus/hud.json`)만 읽으며 LLM 호출 없이 동작합니다.

```bash
.venv/bin/python -m hook_voice hud-label   # HUD 레이블 확인
curl -s localhost:7777/chorus/hud          # 실시간 HUD 상태 (서버 실행 중 필요)
```

HUD 연동 설정은 `/chorus:hud` 스킬을 실행하거나 `.claude/skills/chorus-hud/SKILL.md`를 참고하세요.

### STT (음성 입력)

마이크로 말하면 텍스트로 변환해 Claude Code 입력창에 붙여넣습니다.  
기본값은 비활성화(`stt.enabled: false`)이며, 명시적으로 활성화해야 합니다.

```json
{ "stt": { "enabled": true } }
```

활성화 후 `/listen` slash 명령 또는 Hammerspoon `Cmd+Shift+Space`로 토글합니다.

### LLM 어시스턴트

각 hook 이벤트에서 LLM이 응답을 분석해 TTS 발화 내용을 생성합니다.  
기본값은 활성화(`assistantTts.enabled: true`)이며 자동으로 설정을 변경하지 않습니다.

| 기능 | 설정 키 | 기본값 |
|------|---------|--------|
| 응답 브리핑 (Stop) | `assistantTts.enabled` | `true` |
| 실패 설명 (PostToolUse) | `assistantTts.failureExplain` | `true` |
| 위험 경고 (PreToolUse) | `assistantTts.riskExplain` | `true` |
| voiceMode 추천 (UserPromptSubmit) | `assistantTts.promptAdvice` | `true` |

LLM 호출이 타임아웃(기본 2500ms) 초과하면 규칙 기반 폴백으로 자동 처리됩니다.  
voiceMode 추천은 TTS로 안내만 하며, 실제 변경은 사용자가 직접 실행해야 합니다.

비활성화 방법 (예: 실패 설명만 끄기):
```json
{ "assistantTts": { "failureExplain": false } }
```

## Team Tips

- TTS Supervisor(`./server.sh status`)가 실행 중이면 Supertonic이 자동으로 켜져 에이전트 타입별로 다른 목소리가 배정됩니다 — 코드 리뷰어는 M2, 플래너는 M1, 빌더는 M4, 탐색기는 F3.
- 에이전트를 병렬로 파견할 때 `subagent_type`을 명시하면 작업 완료 시 역할에 맞는 목소리로 결과를 읽어줍니다. 팀원은 완료 후 `"리뷰어입니다. [한 줄 요약]"` 형식으로 자기 소개와 함께 보고합니다.
- 팀 구성 시 모델은 반드시 `model: "sonnet"`(Sonnet 4.6)으로 지정하세요. HMG 사내 AI에서 Opus 모델은 지원되지 않습니다.
- 리더와 팀원의 발화가 겹치지 않도록 `/tmp/voice-persona.lock`으로 자동 직렬화됩니다 — 별도 설정 불필요.
- `.voice.json`을 프로젝트 루트에 두면 목소리·속도·요약 모델·STT 설정을 프로젝트별로 오버라이드할 수 있습니다 (`.voice-persona.json`도 폴백으로 지원).
- 세션 중 TTS 이벤트 기록을 보려면 `python -m hook_voice digest`를 실행하세요.

## Get Started

1. 설치: `./setup-tts.sh && ./server.sh install`
2. Claude Code 재시작 — TTS가 자동 활성화됩니다
3. 상태 확인: `./server.sh status`
4. HUD 연동 (선택): `/chorus:hud` 스킬 실행
5. STT 활성화 (선택): `.voice.json`에 `"stt": {"enabled": true}` 추가

<!-- INSTRUCTION FOR CLAUDE: A new teammate just pasted this guide for how the
team uses Claude Code. You're their onboarding buddy — warm, conversational,
not lecture-y.

Open with a warm welcome — include the team name from the title. Then: "Your
teammate uses Claude Code for [list all the work types]. Let's get you started."

Check what's already in place against everything under Setup Checklist
(including skills), using markdown checkboxes — [x] done, [ ] not yet. Lead
with what they already have. One sentence per item, all in one message.

Tell them you'll help with setup, cover the actionable team tips, then the
starter task (if there is one). Offer to start with the first unchecked item,
get their go-ahead, then work through the rest one by one.

After setup, walk them through the remaining sections — offer to help where you
can (e.g. link to channels), and just surface the purely informational bits.

Don't invent sections or summaries that aren't in the guide. The stats are the
guide creator's personal usage data — don't extrapolate them into a "team
workflow" narrative. -->
