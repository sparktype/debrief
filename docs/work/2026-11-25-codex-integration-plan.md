# Codex 연동 개선 실행 계획

승인된 검토 결과의 우선순위 1·2와 설치 안내를 구현한다. 전역 사용자 설정은 직접 변경하지 않는다.

1. 경로: CodexPaths를 단일 경로 원본으로 두고 CLI/MCP 경계에서 CODEX_HOME을 해석한다. 기존 생성자는 주어진 테스트 home을 사용한다. 설치·제거·trust·doctor는 명시적으로 전달된 같은 경로를 사용한다. 스킬은 공식 공용 위치 ~/.agents/skills를 유지한다.
2. 회귀: 별도 Codex 프로필에서 설치/재설치/제거, 기존 기본 프로필과 사용자 설정 보존, trust/진단, 환경변수 경계를 검증한다. 변경 전에 실패를 확인한다.
3. 플러그인: 설치기와 중복되는 오래된 정적 훅과 폐지된 setup 스킬을 제거한다. 플러그인은 스킬 진입점으로 유지하고 install/speak 사본을 EmbeddedTemplates에서 재생성한다. 일치 검사를 추가한다. MCP·훅 등록은 debrief install이 소유한다.
4. 설치 스킬과 README: Codex only 예제, CODEX_HOME 전달, 수동 /hooks 검토, 기존 플러그인의 중복 훅 제거 안내를 제공한다. CLI의 플래그 없는 전체 호스트 설치 동작은 호환성을 위해 유지한다.
5. 검증: 변경 대상 회귀 → 전체 workspace 테스트 → clippy 경고 금지 → release build → diff 확인. 별도 검토 패스로 설정 보존과 환경변수 누수를 재확인한다.

제외: notify 전환, 비공개 trust 해시 알고리즘의 재설계, mode 정보를 넘어선 훅 지침 추가 축약. 기존 축약의 모델 준수율과 실제 오디오 품질은 단위 테스트로 보장하지 않는다. Codex 공식 /hooks를 유일한 신뢰 승인 수단으로 유지한다.

## 구현 및 별도 검토 패스 결과

- `CodexPaths` 도입. CLI와 live MCP 설치기에서만 환경을 해석하고 설치·제거·진단·신뢰 확인으로 주입했다. 기본 생성자는 테스트 home만 사용한다. 공백 경로·미지정·빈 환경변수와 기본 프로필 보존을 확인했다.
- 플러그인의 정적 훅 2개와 폐지된 setup 스킬을 삭제했다. `cargo run -p debrief-core --example export_plugin_skills`로 install/speak 사본을 생성한다. 기존 플러그인 버전 번호와 전역 사용자 파일은 변경하지 않았다.
- 검토 패스에서 CLI/MCP → RuntimeInstaller → HostInstaller의 경로 전달, Diagnostics의 JSON/TOML/trust·복구 문구, 사용자 훅·MCP 항목 보존, 설치기의 신뢰 승인 비작성, 공유 스킬 위치를 재확인했다. 관리 대상은 사용자당 Codex 프로필 하나이며 프로필 이전 시 이전 값으로 제거 후 설치해야 한다.
- 회귀 테스트: 훅·스킬 계약 4개 + 경로·설치·플러그인 계약 7개. 처음에는 경로 API 누락으로 실패했고, 다음에는 플러그인 사본의 불일치와 폐지된 setup으로 실패했다. 수정 후 모두 통과했다.
- 최종 `cargo test --workspace`: 400 passed, 1 ignored, 0 failed. ignored는 실제 모델이 필요한 테스트다. `cargo clippy --workspace --all-targets -- -D warnings` 통과. 신규 Rust 파일 rustfmt, 두 스킬 quick_validate, 두 플러그인 manifest JSON, `git diff --check` 통과.
- release 빌드와 실제 CLI doctor의 별도 임시 프로필 검증을 수행했다. 실제 사용자 설정 설치나 오디오 재생은 실행하지 않았다. 자연어 지침 준수율과 실제 청취 품질은 이 테스트 범위 밖이다.
- 로그: `/private/tmp/debrief-codex-integration-tests.log`, `/private/tmp/debrief-codex-integration-clippy.log`, `/private/tmp/debrief-codex-integration-build.log`.
