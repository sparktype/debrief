# Reflective Companion Speech Design

**Date:** 2026-07-22  
**Status:** Implemented (P0–P2 shipped on `improve/post-mcp-cleanup`; approved 2026-07-22)  
**Target:** macOS 14+ Apple Silicon, Chorus 2.x  
**Depends on:** MCP speak contract (`2026-07-19-mcp-speak-tool-design.md` + product errata)

---

## 1. Outcome

Chorus remains **TTS-only**. Agents still supply every spoken `text`.  
What changes is the **speech contract and optional wire metadata** so that:

1. **Attitude** — default spoken line is a short *reflective companion* utterance, not a work-report checklist.
2. **Timing** — speech is optional; intentional silence is correct behavior.
3. **Lane (optional product)** — `companion` vs `work` so tone and policy can differ.
4. **Emotion** — restrained affective coloring is part of the companion contract; optional structured `emotion` may bias playback parameters without Chorus inventing wording.

Users should feel a calm helper *beside* the work, not a megaphone reading the chat.

---

## 2. Problem

Today’s contract pushes “one short summary of finished work.” In practice agents emit:

- file/diff inventories,
- “completed A, B, C” checklists,
- every-turn noise with little judgment of whether speech helps.

That is **report mode**. The desired product is **companion mode**: step back, name what matters, offer one next step or rest, with light emotion when appropriate—and stay quiet when speech adds nothing.

---

## 3. Product boundary

### In scope

| Layer | Responsibility |
| --- | --- |
| Agent (skills, hooks, MCP args) | Choose *whether* to speak; write companion/work text; choose voice, speed, volume, priority, optional `lane` / `emotion` |
| Chorus | Validate args; admit/reject via mute/mode/priority/`companionEnabled`/lane; synthesize and play supplied text; **prosody bias** from `emotion` |
| User (menu) | Mute, mode, diagnostics, **도우미 음성** (`companionEnabled`) |

### Out of scope

- Chorus-side LLM, transcript parsing, auto-briefing, speech retouch of free text
- STT / microphone
- Unbounded theatrical emotion, continuous “cheerleading,” or content generation
- HTML/JSON speech envelopes in the chat body
- Changing Supertonic model training or multi-emotion voice packs (unless already supported by existing ONNX path—assume **not** for v1)

---

## 4. Decisions

| Topic | Decision |
| --- | --- |
| Who writes text | **Agent only** |
| Default lane | **companion** (omit `lane` → companion) |
| Companion voice | Prefer **F1** (연아), speed ~0.90–0.93, volume ~0.80–0.85 |
| Work voice | Role map (M3/M4/…); may use existing `priority` for subagent suppression |
| Silence | Valid; preferred over empty report |
| Emotion ownership | Agent selects affective stance; text must carry it; optional enum for playback bias |
| Emotion intensity | **Restrained** for companion (warm, not hyperbolic) |
| Dual speak/turn | At most one companion + one work; prefer single companion line |
| Implementation order | **P0 contract → P1 schema → P2 menu/policy** |

---

## 5. Lanes

| Lane | Purpose | Default voice | Content |
| --- | --- | --- | --- |
| `companion` | Reflective helper | F1 | Observe + meaning + one next step or rest |
| `work` | Factual work report | Role voice | Facts only; no checklist dump; no repeat of companion |

**Per turn**

- companion: 0 or 1  
- work: 0 or 1  
- neither: silence (OK)

If only one `speak` call: treat as **companion** unless the agent explicitly marks work.

---

## 6. Companion text contract (axis 1)

### Structure (target ≤ ~2 short sentences)

1. **Observe** — one factual state slice  
2. **Meaning** — why it matters to the user (half sentence)  
3. **Next** — one next action **or** intentional pause  

### Forbidden in companion

- File/diff/commit inventories  
- “Completed A, B, and C” checklists  
- Paste of chat body  
- Over-praise or performative hype  

### Examples

| Avoid | Prefer |
| --- | --- |
| 문서 세 개를 고치고 Grok 스킬을 추가했고 테스트가 통과했습니다. | 문서와 Grok 배선이 맞춰졌습니다. 설치 한 번과 `/mcps`만 보면 됩니다. |
| 타입 오류 12건을 모두 수정했습니다. | 타입이 한동안 흔들렸습니다. 지금은 안정 쪽이고, 회귀 한 줄만 보면 됩니다. |

---

## 7. Timing and frequency (axis 2)

### Speak (companion) when at least one holds

- Meaningful phase boundary (design locked, implementation done, blocker opened/closed)
- User decision or attention is needed
- Session is long and a *breathing* cue helps
- Failure/risk truly needs user attention

### Stay silent when

- Read-only exploration with no decision  
- Same “still working” as previous turn  
- Intermediate tool thrash  
- Mute, or policy blocks companion (`companionEnabled` off, or mode rejects the request)  
- Everything important is already obvious on screen as a list  

**One-liner:** *If you would only read what the screen already shows, do not speak.*

Subagents: prefer `priority=subagent` and **work** lane if anything; companion is mainly the main agent.

---

## 8. Emotion (approved add-on)

### 8.1 Intent

Companion speech may carry **light affect** so presence feels human without becoming drama.  
Emotion is **not** a second content channel: the spoken sentence still carries meaning; emotion shapes **wording (agent)** and **playback bias (Chorus)** via `EmotionProsody`.

### 8.2 Allowed emotion set (closed enum)

| `emotion` | Companion stance | Text cue (agent) | Playback bias (shipped) |
| --- | --- | --- | --- |
| `neutral` | Calm default | Plain, even | speed/volume unchanged from args |
| `warm` | Gentle encouragement | Soft, supportive, no hype | speed × ~0.97, volume × ~1.00 |
| `focused` | Steady attention | Crisp, minimal | speed × ~1.02 |
| `concerned` | Risk / blocker | Serious, short, no panic | speed × ~0.95, volume slightly up (cap by mode) |
| `relieved` | Tension resolved | Light ease, not celebration | speed × ~0.98 |
| `tired` | Long session / suggest pause | Quiet invitation to rest | speed × ~0.92, volume × ~0.90 |

Default when omitted: **`neutral`**.

### 8.3 Hard rules

1. **Companion emotions only from the table** — no free-string emotion.  
2. **Restrained intensity** — no shouting, guilt, or continuous pep-talk.  
3. **Match content** — `relieved` only when something actually resolved; do not fake affect.  
4. **Work lane** — prefer `neutral` or omit; server forces **neutral** prosody for work regardless of agent `emotion`.  
5. **Mode interaction**  
   - `night` / `quiet`: prefer `neutral` or `tired`; avoid high-arousal wording  
   - `focus`: companion OK if short; avoid `warm` spam  
6. **No Chorus rewriting** — if emotion and text clash, play text as written; bias is mechanical only.  
7. **Privacy** — do not log emotion-derived transcripts; existing no-persist rules apply.

### 8.4 How emotion is expressed without engine “emotion modes”

Supertonic path today has no guaranteed multi-emotion voice model. Therefore:

| Phase | Mechanism |
| --- | --- |
| P0 | Agent wording + speed/volume choices in skill guidance only |
| P1 | Optional MCP `emotion` → multiply effective speed/volume (clamped to envelope ranges) before synthesize/play |
| Later (out of this design unless reopened) | Model-native style tokens if ONNX path gains them |

---

## 9. Wire / MCP shape

### 9.1 Existing (keep)

`text`, `voice`, `speed`, `volume`, optional `priority` (`main` | `subagent`)

### 9.2 Added (P1 — shipped)

| Field | Required | Values | Notes |
| --- | --- | --- | --- |
| `lane` | no | `companion` \| `work` | Default **`companion`** when omitted |
| `emotion` | no | enum in §8.2 | Default **`neutral`**; work lane forces neutral prosody |

Internal UDS `SpeechRequest` carries `lane` and `emotion`.  
`SpeechEnvelope.v` stays **1**. Same-version app + `chorus mcp` is the supported pair.

### 9.3 Host tool names

Unchanged display rules: Claude `mcp__chorus__speak`, Grok `chorus__speak`, etc.

### 9.4 Tool description (normative gist)

Speak a short reflective companion line when speech helps; stay silent when it does not. Prefer observation + meaning + one next step. Optional `lane` and `emotion`. Do not inventory files. Do not put speech metadata in the chat body.

---

## 10. Mode policy extensions (P1/P2)

| Mode | companion | work + subagent | Emotion guidance |
| --- | --- | --- | --- |
| normal | admit | admit | full enum |
| verbose | admit | admit | full enum |
| focus | admit if short (agent); server may only enforce volume | reject subagent work (existing) | prefer neutral/focused |
| quiet | admit + volume ceiling | reject subagent | prefer neutral/tired; bias volume already capped |
| night | admit + low ceiling | reject subagent | prefer neutral/tired; stronger soft speed bias |

**P2 shipped:** user toggle `companionEnabled` in config (menu **도우미 음성**). When false, `ModePolicy` rejects `lane=companion` (work lane still admitted when not muted).

Mute still rejects **all** speech.

---

## 11. Host packaging

### Skills (`chorus-speak` primary)

Rewrite for all hosts (Claude/Codex shared text; Grok `grokSkills` variant):

- companion template + silence rules  
- emotion table + examples  
- lane/voice defaults  
- Grok: `search_tool` / `use_tool` / `/mcps` unchanged  

### Hooks (Claude/Codex)

| Event | Context emphasis |
| --- | --- |
| SessionStart | Full companion + emotion + silence contract |
| UserPromptSubmit | Compact: companion preferred; silence OK; no lists |
| SubagentStart | work + subagent priority; companion discouraged |

### Docs

README / ONBOARDING / DEVELOPER / CLAUDE: companion contract, emotion enum, silence, menu toggle (shipped).

---

## 12. Phased delivery

| Phase | Status | Delivered |
| --- | --- | --- |
| **P0** Contract only | **Shipped** | Skills + hook context: silence, companion structure, emotion in wording, F1 default |
| **P1** Schema + prosody | **Shipped** | MCP `lane` / `emotion`; defaults; `EmotionProsody` bias + clamp; parse/bias tests |
| **P2** User control | **Shipped** | Menu **도우미 음성**; `companionEnabled` config + diagnostics; `ModePolicy` rejects companion when off |

Stricter mode×lane matrix beyond subagent suppression remains **out of scope** unless reopened.

### P0 — Contract only (no schema) — shipped

- Update `chorus-speak` (all install paths) + hook `VoiceCatalog.context`  
- Document silence, companion structure, emotion *in wording*, F1 default  
- No MCP field changes  
- **Exit:** agents in-repo and installed skills teach the new behavior  

### P1 — Schema + light prosody — shipped

- MCP: optional `lane`, `emotion`  
- Validation + defaults  
- Prosody bias table (§8.2) applied to speed/volume after agent values, then clamp  
- Work lane forces neutral prosody  
- Tests for parse/defaults/bias clamps  
- **Exit:** tools/list schema + unit/integration tests green  

### P2 — User control — shipped

- Menu: 도우미 음성 on/off  
- Config key + diagnostics surface  
- `ModePolicy.admit(…, lane:)` rejects companion when `companionEnabled` is false  

---

## 13. Testing

| Area | Cases |
| --- | --- |
| Contract (P0) | Skill/hook fixtures contain silence + companion + emotion vocabulary; no report-checklist examples as recommended |
| Parse (P1) | omit lane → companion; omit emotion → neutral; reject unknown emotion |
| Bias (P1) | emotion multiplies then clamps to speed/volume legal ranges |
| Policy | mute still drops all; subagent work still dropped in focus |
| Backward | old clients sending only four required fields still work |

No requirement to golden-file audio.

---

## 14. Risks and mitigations

| Risk | Mitigation |
| --- | --- |
| Agents ignore contract | Strong skill/hook text; P1 `lane` default companion; optional future soft metrics |
| Emotion becomes melodrama | Closed enum + restrained rules + night/quiet guidance |
| Prosody bias fights agent speed | Apply bias then clamp; document that agent speed is base |
| Scope creep into LLM | Explicit out of scope; reject PRs that summarize on Chorus |
| Too quiet (over-silence) | SessionStart examples of *when* to speak; verbose mode still allows more work reports |

---

## 15. Success criteria

1. Multi-turn sessions include **noticeable intentional silence**, not companion every turn.  
2. Companion lines rarely contain file lists or multi-item completion inventories.  
3. Emotion, when present, is **subtle** and consistent with content.  
4. Chorus never invents text; only validates, admits, biases playback, synthesizes.  
5. Full test suite + release build pass after each phase.

---

## 16. Open points closed by approval

| Point | Resolution |
| --- | --- |
| Axes | **1 + 2 + optional 3** (lanes) |
| Emotion | **In scope** as §8 |
| Companion voice | **F1 preferred** |
| quiet/night | Lower volume ceilings remain; emotion prefers calm/tired; no full companion ban by mode |
| First ship | **P0 → P1 → P2** in order; all three shipped |
| Work + emotion | Prosody forced to `neutral` for `lane=work` |

---

## 17. References

- `docs/superpowers/specs/2026-07-19-mcp-speak-tool-design.md` (+ product errata)  
- `docs/superpowers/specs/2026-07-17-menubar-resident-tts-design.md`  
- `README.md`, `ONBOARDING.md`, `DEVELOPER.md`, `CLAUDE.md`  
- `Sources/ChorusCore/VoiceCatalog.swift`, `McpSpeakTool.swift`, `ModePolicy.swift`
