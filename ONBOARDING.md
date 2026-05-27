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
- [ ] summary-voice-mcp — github.com/sparktype/summary-voice-mcp

### MCP Servers to Activate
  _(none recorded in the last 30 days)_

### Skills to Know About
  _(none recorded yet — ask your teammate which skills they reach for most)_

## Team Tips

- TTS Supervisor(`./server.sh status`)가 실행 중이면 Supertonic이 자동으로 켜져 에이전트 타입별로 다른 목소리가 배정됩니다 — 코드 리뷰어는 M2, 플래너는 M1, 빌더는 M4, 탐색기는 F3.
- 에이전트를 병렬로 파견할 때 `subagent_type`을 명시하면 작업 완료 시 역할에 맞는 목소리로 결과를 읽어줍니다. 팀원은 완료 후 `"리뷰어입니다. [한 줄 요약]"` 형식으로 자기 소개와 함께 보고합니다.
- 팀 구성 시 모델은 반드시 `model: "sonnet"`(Sonnet 4.6)으로 지정하세요. HMG 사내 AI에서 Opus 모델은 지원되지 않습니다.
- 리더와 팀원의 발화가 겹치지 않도록 `/tmp/voice-persona.lock`으로 자동 직렬화됩니다 — 별도 설정 불필요.
- `.voice.json`을 프로젝트 루트에 두면 목소리·속도·요약 모델·STT 설정을 프로젝트별로 오버라이드할 수 있습니다 (`.voice-persona.json`도 폴백으로 지원).

## Get Started

_TODO_

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
