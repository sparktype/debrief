# 컨텍스트 노트

## 2026-09-30 코드 오너십 노티
- 목적은 인지 부채 최소화. 사용자가 코드 오너십(이해·통제)을 잃지 않게 한다.
- 전달 채널은 기존 음성 브리핑 통합으로 결정. 새 도구·새 speak 호출 없음, 턴당 0–1회 유지.
- "다음 행동" 자리에 직접 확인할 핵심(동작 변경·삭제·보안/데이터 경로, 에이전트의 가정, 확인/되돌리기 방법)을 넣는다. 문장은 에이전트가 쓴다.
- 서브에이전트는 적용 제외. 사소한 변경은 기존 규칙대로.
- 한계: 문구 계약이라 에이전트 준수를 코드로 강제할 수 없다.
- UserPromptSubmit 컨텍스트는 400자 미만 테스트가 있어 문구를 짧게 유지한다.

## 2026-10-01 CI 소켓 테스트 실패
- 직접 원인: 모든 소켓에 걸린 SO_RCVTIMEO 150ms. 클라이언트가 ACK를 그 안에 못 받으면 `read`가 EAGAIN(35)으로 실패하고 재시도하며, 서버가 이미 처리했다면 같은 발화가 중복될 수 있다.
- 로컬에서 서버 ACK를 400ms 늦추는 테스트로 CI와 같은 `systemCall("read", 35)`를 재현했다.
- 수정: 클라이언트만 ACK 읽기 직전에 타임아웃을 2초로 늘린다. connect·write는 150ms 유지.
- CI(Swift 6.1.2, 적은 코어)에서만 실패한 이유는 미확정. CI 통과 여부로 확인한다.
- 정정: 1차 수정(ACK 2초)만으로는 CI가 실패했고 오히려 더 오래 막혔다. 존재하지 않는 소켓 연결 테스트가 4초 걸린 것은 클라이언트 Task.detached가 협력 스레드 풀 고갈로 시작하지 못했다는 뜻이다. 150ms는 원인이 아니라 증상.
- 2차 수정: 클라이언트의 블로킹 syscall을 서버 accept처럼 DispatchQueue.global로 옮겨 협력 풀을 붙잡지 않게 한다.

## 2026-10-07 categoryVoices 연결
- 역할 목소리는 재생 경로가 아니라 훅이 에이전트에게 안내하는 문구(SubagentStart·시작 훅의 "role voice")에만 쓰인다. 실제 재생 목소리는 에이전트가 speak에 넘기는 `voice`다. 그래서 연결 지점은 `voice_catalog.rs`의 context 생성 하나이고 MCP·데몬은 건드리지 않았다.
- `context` 시그니처를 바꾸면 기존 호출과 테스트가 줄줄이 깨져서, 새 `context_with_voices`를 만들고 `context`는 빈 맵으로 위임하게 했다.
- 덮어쓰는 것은 voice와 name뿐이고 baseline_speed는 역할 값을 유지한다(속도는 voiceSpeeds의 몫이며 아직 연결하지 않았다).
- 허용 목록(F1–M5)에 없는 값, 알 수 없는 역할 키는 조용히 무시한다(fail-open, 기존 동작).
- 도우미(companion) 세션 목소리 로테이션은 건드리지 않는다. `default` 키로 미등록 에이전트의 목소리는 바꿀 수 있다.
- 플러그인 스킬(sparktype/claude-plugins)은 아직 "효과 없음"으로 적혀 있다. 이 변경이 릴리스되기 전에는 그 설명이 현재 배포본에 맞다.

## 2026-10-07 의존성 업그레이드
- 직접 의존성 중 뒤처진 것은 libc(패치)와 sha2(0.10→0.11)뿐이었다. 나머지와 ort(rc.13이 최신 프리릴리스)는 이미 최신이었다.
- sha2 0.11은 0.x 호환 깨짐 가능성에 비해 얻는 기능이 없고 설치 기록·모델 무결성 검증 경로(54곳)라 보류했다. 필요해지면 별도 작업으로 한다.
- ort는 Cargo.toml이 rc.7로 적혀 있었으나 프리릴리스 캐럿 범위 덕에 잠금은 이미 rc.13이었다. 요구 버전만 rc.13으로 올려 실제와 맞췄다(동작 변화 없음).
- cargo-audit를 새로 설치했다(~/.cargo/bin). 이후 업그레이드 때 `cargo audit`를 같이 돌린다.

## 2026-10-14 TTS 모델 재검토 → Supertonic 3 유지
- 후보 실측(M1 Max): Chatterbox Multilingual ONNX RTF 2.3~3.7·4.4GB, MOSS-TTS-Nano RTF 0.28(청취 결과 어울리지 않음), MOSS-TTS-Local v1.5 MLX 복제 RTF 1.25~2.62·12.5GB·감정 지시 시 생성 폭주. 8B·Seamless(비상업)는 문서 검토로 탈락.
- HF Open TTS Leaderboard 한국어(CV3-Eval)에서 Supertonic 3가 WER 3.6·RTFx 56.7로 1위. 약점은 스트리밍이 없어 첫 소리까지 지연(CPU p50 1.55초).
- 그래서 모델 교체 대신 (1) 문장 단위 선재생, (2) Supertonic 안의 감정 표현으로 간다.

## 2026-10-14 문장 단위 선재생 + 감정 표현
- 기존 `split_text(text, 120)`는 120자까지 문장을 한 청크로 묶어 두 문장 브리핑이 청크 하나였다. 선재생하려면 문장마다 청크를 나눠야 한다.
- 합성과 재생을 겹치기 위해 데몬이 재생 스레드를 두고 채널로 문장 PCM을 받는다. `AudioPlaying::play`는 재생이 끝날 때까지 막히므로, 같은 스레드에서 합성·재생하면 겹치지 않는다.
- 문장 사이 쉼은 엔진이 아니라 데몬이 두 번째 문장부터 앞에 무음을 붙인다(감정별 길이를 core가 결정). 기존 고정 0.3초는 neutral 값으로 유지.
- 표현 태그 청취 실험: `<laugh>`는 또렷, `<sigh>`·`<breath>`는 거의 들리지 않음(음성 길이만 0.3~0.5초 늘어남). 사용자는 세 가지 모두 쓰기로 선택.
- 태그 매핑(가정): relieved→`<laugh>`, warm→`<breath>`, tired→`<sigh>`. concerned에 한숨은 짜증처럼 들릴 수 있어 태그 없음. 표 하나라 바꾸기 쉽다.
- 태그는 core가 텍스트 맨 앞에 붙인다(Supertonic 전용 문법이 core에 들어가는 대가로 TtsBackend 시그니처 변경을 피함). 에이전트가 태그를 직접 넣지 못하게 사용자 텍스트의 `<` `>`는 지운다.
- 동작 변화: 중간 문장 합성이 실패하면 앞 문장은 이미 재생된 상태로 오류를 기록한다(기존에는 아무것도 재생하지 않음).

## 2026-10-14 Supertonic 3 모델 미러
- Supertone Voice Builder 사이트(supertonic.supertone.ai)가 404. 본 사이트·GitHub·HF `Supertone/supertonic-3`(고정 리비전 3cadd1ee)은 살아 있다.
- 원본 소실에 대비해 `codeguru76/supertonic-3`(공개, 커밋 f26b6b0ac3583e5fc3706cb21d70c3c6cfc3f316)에 원본 리비전을 그대로 미러하고 출처를 밝히는 `MIRROR.md`만 추가했다. 매니페스트 자산 16개의 크기·sha256 일치 확인.
- OpenRAIL-M 4항: 재배포 허용. 라이선스 사본 제공, 출처 표시 유지, Attachment A 사용 제한 전달이 조건. 파일을 수정하지 않았으므로 4.c(수정 표시)는 해당 없음.
- 결정: debrief는 계속 원본에서 받는다. 원본이 사라지면 `ModelManifest::supertonic3`의 base URL을 미러로 바꾼다. sha256은 같고 revision만 미러 커밋으로 바뀐다.

## 2026-10-14 감정 표현 청취 튜닝 (v0.2.2)
- v0.2.1 값(속도 계수 0.92~1.02, 쉼 0.2~0.5초)은 실제 데몬 청취에서 "차이가 안 느껴짐".
- 속도·쉼을 두 단계 키운 샘플(속도 0.78~1.18, 쉼 0.1~1.1초) 뒤, 사용자가 "속도는 모델 기본 속도로" 결정. Supertonic 공식 기본 속도는 1.05(`helper.py`).
- 최종: 감정이 속도를 바꾸지 않는다(에이전트가 보낸 speed 그대로). 쉼 focused 0.1 / neutral 0.3 / relieved 0.55 / warm 0.7 / concerned 0.8 / tired 1.1초, 볼륨 tired ×0.75·concerned ×1.05, 태그는 그대로.
- 훅이 안내하는 기본 speed(~0.93~1.10)는 바꾸지 않았다(사용자가 그 선택지를 고르지 않음).

## 2026-10-18 에이전트 사용성 기능 5개
- 사용자가 질문 없이 바로 진행을 선택했다. 각 기능의 세부는 에이전트 판단이며 아래에 근거를 남긴다.
- 1번: 데몬은 지금까지 요청의 세션을 몰랐다. MCP speak의 `session`을 SpeechRequest·소켓 프레임(`session`)에 실어 데몬까지 보낸다. 끊는 대상은 같은 세션 + companion lane + 결정 대기 아님. 훅 알림(work lane)과 다른 세션, 결정 대기는 남긴다. session 없이 온 speak는 끊을 수 없다(호스트 context가 session을 안내하므로 대부분 실린다).
- 1번: UserPromptSubmit마다 데몬 소켓에 제어 프레임 하나를 보낸다. 데몬이 꺼져 있으면 끊을 것도 없으므로 전송 실패는 last-error에 기록하지 않는다(알림 실패 기록을 덮지 않게).
- 2번: 별도 lexicon 파일 대신 데몬이 발화마다 이미 읽는 `config.json`에 `pronunciations` 맵을 둔다(새 로더·경로 없이 재시작 없이 반영). 기본값은 비어 있다 — 어떤 용어를 어떻게 읽을지는 사용자 취향이라 내장 사전을 넣지 않았다.
- 2번: 매칭은 ASCII 영숫자 경계 + ASCII 대소문자 무시, 긴 키 우선. 한국어 조사가 바로 붙어도("MCP를") 경계로 본다. 치환은 EmotionProsody 앞에서 하므로 사전 값의 `<` `>`도 지워져 태그 주입이 안 된다. replay 기록은 원문을 유지하고 재생 때 다시 적용된다.
- 3번: 들어온 시각은 SpeechRequest가 아니라 대기열 내부(`Pending`)에 둔다 — 프레임·리터럴 12곳을 건드리지 않는다. 최대 대기 45초는 상수(테스트만 `with_max_wait`). 두 문장 브리핑 재생이 5~8초라 앞에 5~6개가 밀린 수준이다. 결정 대기와 replay는 사용자가 꼭 들어야 하므로 만료하지 않는다. 버릴 때 last-error에 기록하지 않는다(정상 동작).
- 3번: 서브에이전트 합치기는 "아직 재생 시작 전" 서브에이전트 항목이 있을 때만. 합쳐지면 각 사실 문장은 잃고 개수만 남긴다(첫 항목의 목소리·세션 유지). main이 오면 기존대로 대기 중 서브에이전트를 버린다.
- 3번 TDD 순서: 대기열 구현을 먼저 하고 테스트를 뒤에 붙였다(기존 테스트 1건이 바뀐 동작으로 깨져 그 테스트를 합치기 검증으로 바꿈).
- 4번: 신호는 CoreAudio `kAudioHardwarePropertyProcessObjectList`('prs#') + 프로세스별 `kAudioProcessPropertyIsRunningInput`('piri'). 기본 입력 장치의 `DeviceIsRunningSomewhere`는 헤드셋처럼 입출력이 같은 장치면 debrief 자신의 재생·음악 재생에도 켜져 오탐이라 버렸다. 새 의존성 없이 CoreAudio FFI(이미 cpal이 링크) 30줄. 마이크 권한(TCC)이 필요 없고 녹음하지 않는다.
- 4번: macOS 14.2 미만이면 읽기 실패 → 꺼진 것처럼 동작, doctor가 `mic.unreadable`. 이 Mac(27.2)에서 `Some(false)` 판독 확인. 실제 통화 중 `true`가 되는지는 에이전트가 확인하지 못함(마이크를 켜려면 권한이 필요).
- 4번: 방해금지와 같은 규칙(night 유지, 저장 모드 불변). 훅 모드 지침의 `(dnd)` 표시는 마이크로 올라가도 그대로 붙는다(문구만 부정확, 동작 영향 없음).
- 5번: 호스트는 Gemini CLI로 정했다. 공식 문서로 컨텍스트 주입(SessionStart·BeforeAgent `hookSpecificOutput.additionalContext`)과 MCP(`settings.json` `mcpServers`)를 확인했다. Cursor는 프롬프트 훅의 컨텍스트 주입을 공식 문서로 확인하지 못해 보류.
- 5번: Gemini는 옵트인. 플래그 없는 `install`은 manifest에 Gemini 훅이 있을 때만 Gemini를 포함하고(repair가 계속 고치도록), 플래그 없는 `uninstall`은 항상 포함한다(바이너리를 지운 뒤 낡은 훅이 남지 않게). MCP `install` 도구 기본값에는 넣지 않았다.
- 5번: `trust: true`는 넣지 않았다(Gemini 도구 확인을 모두 건너뛰게 되어 install 도구까지 무확인 실행). 사용자가 Gemini에서 항상 허용을 고르면 된다.
- 5번: doctor는 Gemini 훅 누락(`hooks.gemini.*`)과 설정 JSON 손상(`host.gemini.invalid_json`)만 보고하고, MCP 상태 목록(`statuses`)에는 넣지 않았다 — 옵트인 전 `~/.gemini/settings.json`이 있으면 `mcp.gemini.missing` 경고가 늘 뜨기 때문.
- 사고(5번 검증 중): 임시 HOME으로 `debrief install --gemini`를 실행했더니 실제 사용자 세션 `gui/501/com.debrief.tts` 라벨이 임시 바이너리로 올라갔다. 바로 bootout해 되돌렸다(테스트 전에도 데몬은 꺼져 있었음). 앞으로 install 스모크 테스트는 임시 HOME이어도 launchctl을 건드리므로 실행하지 않는다.

## 2026-10-27 에이전트 연동 강화 6개
- 사용자가 조사 추천 6개를 "모두 추가"로 승인. 세부는 에이전트 판단이며 근거를 아래에 남긴다.
- 근거 문서: Claude Code hooks(code.claude.com/docs/en/hooks), channels-reference, Codex hooks(learn.chatgpt.com/docs/hooks). 2026-10-27 조회.
- Codex 이벤트 12종 중 PreCompact·PostCompact(`trigger` manual|auto)·Interrupt(`turn_id`, 메인 스레드만)를 추가한다. SubagentStop은 기존 결정대로 설치하지 않는다.
- 3번은 옵트인(기본 꺼짐). 의도적 침묵(Silence only)도 한 번 되돌려지므로 비용(모델 1회)과 마찰이 있다. 임계값은 새 설정 없이 `longTurnSeconds`를 재사용해 "긴 턴 완료 알림"을 대체하는 위치에 둔다. 되돌린 뒤에도 말하지 않으면 기존 완료 알림으로 떨어진다. mute·quiet·night에서는 되돌리지 않는다(지침이 침묵을 허용).
- Claude Stop은 `decision: block` 대신 `hookSpecificOutput.additionalContext`를 쓴다(문서: 오류 알림 없이 "Stop hook feedback"으로 표시, 같은 루프 보호). Codex Stop은 additionalContext 미지원이라 `decision: block` + `reason`.
- 4번 terminalSequence는 Claude 전용. Ghostty·Warp는 OSC 777, 그 밖은 OSC 9(`TERM_PROGRAM`으로 고름).
- 1번 작업 중 발견한 버그: 클라이언트가 데몬 accept 전에 닫히면 `setsockopt(SO_NOSIGPIPE)`가 EINVAL(22)을 내고 `SystemCall`로 분류돼 회복 불가 → 데몬 accept 루프 종료. 훅이 타임아웃으로 죽는 경우에도 날 수 있었다. 소켓 설정을 클라이언트별 실패(InvalidFrame)로 옮겨 고쳤다(4859392).
- 1번 프로브(`UnixSocketClient::is_reachable`)는 연결 후 쓰기만 닫고 NAK/EOF를 최대 300ms 기다린다. 바로 닫으면 위 버그가 있는 구버전 데몬(≤0.3.2)을 멈추게 하므로 이 방식을 쓴다. UserPromptSubmit은 이미 보내는 SkipSession 제어의 성공 여부를 그대로 쓴다(`SystemCall` 오류만 끊김으로 본다, `Rejected`는 구버전 데몬이 살아 있다는 뜻).
- 1번 경고는 세션당 10분 쿨다운(`daemon_unreachable` 알림 키 재사용), 음소거면 내지 않는다(침묵이 의도). Gemini는 `systemMessage` 지원을 확인하지 않아 제외.
