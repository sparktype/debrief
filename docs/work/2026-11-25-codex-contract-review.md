# Codex 훅·스킬 계약 검증

후속 구현 상태: `CODEX_HOME` 경로 통일, 플러그인 스킬 단일 원본·중복 훅 제거, Codex 전용 설치 안내를 반영했다. 아래 검토 내용은 구현 전 근거이며, 실행 결과는 [개선 실행 계획](2026-11-25-codex-integration-plan.md)에 기록한다.

목표: 진행 중인 훅·스킬 축약 작업을 보존하면서 Codex에서 실제 소비되는 출력과 설치 결과를 검증한다. 제품 경로는 `HostInstaller` → JSON 훅 → `HookCommandRunner` → `HookEngine` → `VoiceCatalog`이며, 발화는 별도 MCP `speak`가 담당한다.

근거: 축약 전 UserPromptSubmit 문구는 Claude 기준 386자로 새 260자 제한 테스트에 실패했다. Codex는 도구와 서버를 함께 식별해야 하므로 별도로 실제 UUID 세션과 모드 지침을 포함한 출력 크기를 검증한다. 공용 speak 스킬 설명은 Codex를 누락했고, 축약 중 본문의 HTML/JSON 출력 금지 지침이 빠졌다.

범위와 순서:

- [x] `tests/codex_hook_skill_contract.rs`에 외부 공개 API를 통한 회귀 테스트 추가: Codex 네이티브 입력 → 유효 JSON 출력, 같은 세션의 고정 목소리 유지, 모드별 지침과 세션 재생 중단 유지, 서브에이전트 역할 목소리 유지.
- [x] 설치된 공용 speak 스킬의 Codex 검색 메타데이터 및 채팅 본문 금지 지침을 검증한다. Codex 누락으로 처음 실패했고, 병행 축약 작업에서 해당 메타데이터와 HTML/JSON 금지 문구가 보완된 뒤 통과했다. 이 검토에서는 템플릿·설치기 구조를 수정하지 않았다.
- [x] 통합 테스트 4개, 전체 workspace 테스트 393개 통과(1개 ignored), clippy 경고 0, release 빌드 성공. 전체 테스트의 Unix 소켓 bind 제한은 동일 검증 명령만 sandbox 밖에서 재실행해 해소했다.

불변 계약: 음소거·quiet·night·영어 모드, `intent=decision`, 세션 식별, 서브에이전트 priority/lane, 사용자가 수정한 설치 파일 보존. 새 의존성·실제 사용자 설정 변경·훅 신뢰 우회 없음.

한계: 구조/출력 계약 테스트는 모델의 자연어 지침 준수율이나 실제 음성 청취를 입증하지 않는다. 서브에이전트 검토는 계정에서 설치 역할 모델을 지원하지 않아 실행되지 않았다.

## 연동 방식 검토 결과

기준: 로컬 Codex CLI `0.172.0`과 2026-11-25 확인한 공식 문서. MCP → Unix 소켓 → 상주 데몬은 모델을 매 턴 다시 로드하지 않고 에이전트가 고른 문장을 재생하는 목적에 맞는다. 주된 개선점은 이 경로의 교체보다 설정과 지침의 소유권 정리다.

### 1. 높은 우선순위: CODEX_HOME 일관성

**근거:** `host_installer.rs:609`의 `settings_url`, `:619`의 `mcp_toml_config_url`, `codex_trust.rs:86`의 `review_required`가 모두 `home/.codex`를 직접 사용한다. 공식 Codex는 `CODEX_HOME`을 별도로 지정할 수 있다.

**영향:** 기본 경로가 아닌 Codex를 사용하면 설치 성공과 실제 로딩 경로가 어긋나거나 다른 프로필 설정을 수정할 수 있다. 실제 이 환경의 실패를 재현한 것은 아니다.

**권고:** Codex 설정 루트를 한 곳에서 결정해 설치·제거·MCP 상태·훅 신뢰 진단에 함께 전달한다. 테스트용 home 주입을 보존하고 환경변수에 의존하는 전역 테스트는 피한다. 공유 스킬의 `~/.agents/skills`는 Codex 설정 루트와 별개다.

문서: [Codex 설정·상태 위치](https://learn.chatgpt.com/docs/config-file/config-advanced#config-and-state-locations).

### 2. 높은 우선순위: 설치기와 플러그인 사본의 분리

**근거:** 설치기 생성본은 MCP와 9개 Codex 이벤트를 설치하지만 `plugins/debrief/hooks/hooks.json`에는 시작 계열 3개만 있다. 플러그인의 `.codex-plugin/plugin.json`에는 스킬만 선언되어 있고 MCP 등록은 없다. `CODEX_HOME` 유무로 Codex/Claude를 판별하며, 정적 speak 스킬은 현재 생성본의 mode·intent·ownership 계약보다 오래됐다.

**영향:** 플러그인만 설치하면 실행 파일·데몬·MCP가 준비되는 것은 아니다. 두 경로를 함께 설치하면 별개의 훅 출처가 생기므로 중복 호출 가능성이 있다. 실제 동시 설치에서 중복 재생을 관찰한 것은 아니다.

**권고:** 당장은 `debrief install --codex`를 정식 경로로 명시하고 정적 사본을 배포용 생성물로 통일하거나 은퇴시킨다. 중기적으로 로컬 데스크톱 플러그인에 MCP·스킬·훅을 묶는 방식은 가능하지만, 네이티브 런타임 설치와 훅 신뢰 검토는 여전히 필요하다. 공식 문서상 훅 포함 플러그인은 수동 설치 Codex desktop 지원이며 공개 디렉터리 제출 대상이 아니므로 전면 플러그인 전환을 즉시 권하지 않는다.

문서: [MCP·훅 패키징과 지원 범위](https://developers.openai.com/plugins/build/plugins#bundled-mcp-servers-and-lifecycle-hooks).

### 3. 중간 우선순위: 정적 규약과 동적 훅 상태 분리

**근거:** `voice_catalog.rs:180`은 매 프롬프트에 브리핑 규약을 넣고, `embedded_templates.rs:173`의 스킬 및 `mcp_server.rs:68`의 도구 설명도 같은 내용을 담는다. 다만 `HookEngine`의 UserPromptSubmit은 세션의 이전 발화를 끊고, 모드·언어·목소리·세션 음소거 변경도 전달한다.

**권고:** SessionStart/스킬에 정적 규약을 두고 UserPromptSubmit은 짧은 턴 종료 알림과 현재 세션·모드만 남긴다. 훅 전체 삭제는 취소·음소거 갱신을 잃으므로 부적합하다. 상태가 바뀔 때만 컨텍스트를 출력하는 추가 최적화는 재개·압축 후 복원 및 누락률 비교를 먼저 검증한다. 문자 수 감소는 토큰 비용·브리핑 준수율·지연 개선의 실측값이 아니다.

문서: [UserPromptSubmit의 developer context](https://learn.chatgpt.com/docs/hooks#userpromptsubmit).

### 4. 중간 우선순위: 신뢰 상태 판별의 버전 결합

**근거:** `codex_trust.rs:3`은 2026-10 Codex 내부 정규화·해시 및 그룹 인덱스를 재현한다고 명시한다. 이는 공식 훅 계약 외에 별도의 유지보수 부담을 만든다. 현재 버전에서 해시가 틀렸다는 증거는 없다.

**권고:** 신뢰 우회나 자동 승인은 추가하지 않는다. 공식 `/hooks` 검토를 기준으로 삼고, 진단 구현은 지원 Codex 버전별 fixture와 확인 불가 상태를 분리한다. 플러그인으로 옮겨도 훅 신뢰 검토는 없어지지 않는다.

문서: [훅 검토·신뢰](https://learn.chatgpt.com/docs/hooks#review-and-trust-hooks).

### 5. 중간 우선순위: 발화와 설치 도구의 범위

**근거:** `mcp_toml_fragment`는 speak와 install을 모두 노출하며, MCP install의 hosts 생략은 Codex·Claude·Grok 세 호스트를 선택한다. Codex 전용 복구에는 넓은 기본 범위다.

**권고:** Codex용 설치 예시는 `hosts: ["codex"]`를 기본으로 하고, 자주 쓰는 speak와 설정을 변경하는 install의 도구 승인 정책을 따로 설정할 수 있게 안내한다. 사용자가 지정한 정책은 설치기가 덮어쓰지 않는다. 스키마를 줄여 voice/speed/volume을 선택값으로 만드는 것은 호환성 검증 후 검토할 후순위 개선이다.

문서: [MCP 도구 필터와 도구별 정책](https://learn.chatgpt.com/docs/extend/mcp).

## 대안 비교와 권고 구성

| 방식 | 장점 | 한계 | 판단 |
| --- | --- | --- | --- |
| 현재 MCP + 최소 훅 + 로컬 데몬 | 에이전트가 고른 두 문장, 감정·세션 제어 유지 | 추가 도구 호출 및 지침 필요 | 현재 목적에 권장 |
| `notify`의 agent-turn-complete | 완료 알림에 모델 도구 호출 불필요 | 최종 응답 전달이지 별도 두 문장 브리핑 생성이 아님; 권한·중단 이벤트 대체 불가 | 단순 완료음 전용 옵션 |
| 스킬 + MCP만 사용 | 설치·신뢰 관리 감소 | 자동 매 턴 실행 보장 없음; 세션별 취소·동적 상태 전달 손실 | 수동 브리핑용 옵션 |
| MCP·스킬·훅 묶음 플러그인 | 배포/활성화 단위 통일 | 로컬 네이티브 설치와 신뢰는 남음; 훅 배포 범위 제한 | 중기 패키징 개선 |

`notify` 근거: [공식 알림 설정](https://learn.chatgpt.com/docs/config-file/config-advanced#notifications). 권고 순서는 CODEX_HOME 경로 정리 → 플러그인/설치기 단일 원본 → 동적 훅 최소화다. 현재 검토에서는 런타임·전역 설정·설치 방식을 바꾸지 않았다.
