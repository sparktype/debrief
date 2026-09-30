# debrief Rust 재작성 — 설계

## 배경과 동기

debrief는 지금 Swift 단일 바이너리(macOS 14+, Apple Silicon 전용)로 구현되어 있다. 0.0.4 배포 과정에서 `launchctl bootstrap`이 macOS Background Task Management(BTM)의 알림 속도 제한에 걸려 EIO로 실패하는 문제를 겪었고, 근본 원인은 BTM(언어와 무관한 시스템 데몬)이었지만 이 사건을 계기로 두 가지를 재점검했다.

1. **배포 방식**: Homebrew formula가 `swift build -c release`로 사용자 기계에서 소스를 빌드한다. Xcode 27 전체 설치를 요구하고, 빌드마다 10초 이상 걸리고, 사용자 환경(Xcode 버전 차이, Command Line Tools vs 정식 Xcode)에 따라 실패할 수 있다.
2. **툴체인 자체의 불편**: Swift Testing 매크로가 Command Line Tools만으로는 동작하지 않아 이 저장소의 테스트가 특정 개발 환경에서 실행 불가능한 채로 남아 있다.

이 두 가지가 겹쳐, 언어와 배포 방식을 함께 바꾸기로 했다. Rust로 재작성하고, Homebrew는 소스 빌드 대신 프리빌트 바이너리를 받는 방식으로 바꾼다.

**주의**: BTM 쓰로틀링 자체는 launchd/BTM이라는 macOS 시스템 계층의 동작이라 언어 전환으로 사라지지 않는다. 0.0.4에서 도입한 "실행 파일·plist 내용이 안 바뀌고 데몬이 건강하면 재부트스트랩을 건너뛴다"는 로직은 Rust 버전에도 그대로 옮긴다.

## 범위

전체 재작성. CLI/데몬 제어, MCP 서버(stdio JSON-RPC), LaunchAgent 설치·관리, Unix 소켓 클라이언트/서버, 호스트별(Claude Code/Codex/Grok) 훅·스킬 배선, Supertonic TTS 추론까지 전부 Rust로 옮긴다. 기존 Swift 소스는 재작성 완료 후 삭제한다.

- **리포**: 같은 리포(`sparktype/debrief`), 새 브랜치(`feature/rust-rewrite`)에서 작업. 완료되면 `main`에 병합하고 Swift 소스를 제거한다.
- **버전**: 0.0.x를 마감하고 `0.1.0`부터 시작한다. 언어·배포 방식·다국어 지원이 함께 바뀌는 것을 이 경계로 표시한다.
- **플랫폼**: 지금은 macOS 전용이지만, 오디오 재생/프로세스 매니저 계층을 크레이트 경계로 분리해 향후 Linux(systemd) 확장이 가능하게 열어둔다. 이번 재작성에서 Linux 지원을 실제로 구현하지는 않는다.

## 아키텍처

기존 구조(단일 바이너리 + LaunchAgent 상주 데몬 + Unix 소켓 + stdio MCP)를 그대로 유지한다. 구조 문제가 아니라 언어·배포 문제였기 때문이다.

**동시성 모델: 동기(`std`), async 런타임 없음.** Swift 버전은 `async`/`await`를 쓰지만 `actor`(직렬화 큐 하나)로 귀결되어 실질적 동시성이 없다 — Rust에서 `tokio` 같은 비동기 런타임을 들여와도 얻는 게 없고, 데몬/소켓/MCP 서버 전체에 async 전파 비용만 생긴다. 대신 표준 라이브러리로 충분히 감당한다: `std::net::UnixListener`로 소켓 서버, 필요하면 `std::thread`로 연결당 스레드, HTTP 다운로드는 동기 클라이언트 `ureq`. 아래 각 컴포넌트 설계에서 `async fn`/`tokio::sync::Mutex` 등 비동기 표기가 나오면 전부 동기 대응(일반 `fn`, `std::sync::Mutex`)으로 읽는다 — 초안 작성 시점에는 아직 이 결정 전이라 async 표기가 남아 있다.

```
                    ┌───────────────────────────┐
                    │   debrief (단일 바이너리, Rust)  │
                    ├───────────────────────────┤
CLI 서브커맨드 →      │ install/uninstall/daemon/    │
                    │ start/stop/status/doctor/    │
                    │ mute/mode/companion/hook/mcp │
                    ├───────────────────────────┤
호스트 spawn →        │ mcp (stdio JSON-RPC)        │──┐
                    ├───────────────────────────┤  │ Unix Domain Socket
LaunchAgent →         │ daemon (ResidentService)    │◄─┘
                    │  ├─ UnixSocketServer         │
                    │  ├─ SpeechQueue              │
                    │  ├─ debrief-tts(추론 엔진)      │
                    │  └─ cpal(오디오 재생)           │
                    └───────────────────────────┘
```

### 크레이트 구성

Swift의 `DebriefCore`/`DebriefCLI` 2-모듈 구조를 3-크레이트로 대응시킨다.

| 크레이트 | 역할 | 대응하는 기존 Swift 파일(대표) |
|---|---|---|
| `debrief-core` (lib) | 설정, 설치/훅/스킬 배선, MCP 서버, 큐, 진단, LaunchAgent 제어 | `DebriefConfiguration`, `HostInstaller`, `McpServer`, `SpeechQueue`, `Diagnostics`, `LaunchAgentControl`, `RuntimeInstaller` |
| `debrief-tts` (lib) | ONNX 추론, 텍스트 전처리/청킹, 보이스 스타일 로딩 | `SupertonicEngine`, `SupertonicTensor`, `VoiceCatalog`(음성 카탈로그 매핑은 core에 남기고, 텐서/추론만 이 크레이트) |
| `debrief` (bin) | CLI 엔트리포인트, 서브커맨드 라우팅 | `EntryPoint.swift` |

### 컴포넌트별 설계

#### 1. TTS 추론 (`debrief-tts`)

supertone-oss-archive/supertonic의 `rust/` 참조 구현(MIT, Supertone Inc.)을 라이브러리로 이식한다. 조사 결과 이 참조 구현은 CLI 바이너리 전용(`[lib]` 타깃 없음)이라 다음을 바꿔 임베드한다.

- `helper.rs`의 로직(`TextToSpeech`, `load_text_to_speech`, `load_voice_style`, `chunk_text`, `UnicodeProcessor`)을 `debrief-tts` 라이브러리 크레이트로 분리한다.
- CLI 전용 종료 해킹(`mem::forget(text_to_speech)` + `libc::_exit(0)` — ONNX Runtime의 Drop을 건너뛰는 1회성 프로세스 종료 트릭)을 제거한다. 데몬은 여러 요청을 처리하며 정상적으로 리소스를 해제해야 한다.
- `_infer`/`call`/`batch`가 현재 `&mut self`이므로, Swift의 `actor SupertonicEngine`과 동등하게 세션 하나를 `std::sync::Mutex`로 감싸 동시 요청을 직렬화한다(동시성 모델은 위 아키텍처 절 참고 — async 아님).
- ONNX 그래프 4개(`duration_predictor`, `text_encoder`, `vector_estimator`, `vocoder`)와 텐서 이름·shape은 Swift 버전과 동일하므로 모델 자산(`ModelManifest.supertonic3`)은 그대로 재사용한다 — URL/체크섬 변경 없음.
- **다국어**: 참조 구현은 `--lang`으로 31개 언어를 지원하고 `AVAILABLE_LANGS`로 검증한다. debrief는 현재 `<ko>` 고정이었으나, 이번 재작성에서 이 파라미터화를 그대로 들여온다. MCP `speak` 도구에 선택적 `lang` 파라미터를 추가하고, 생략 시 기본값 `ko`로 지금과 동일하게 동작시킨다(§4 참고).
- **텍스트 청킹**: 참조 구현은 ko/ja는 120자, 그 외 언어는 300자 기준으로 문단→문장→쉼표→단어 순으로 폴백하며 분할한다. Swift 버전의 단순 120자 고정 로직보다 정교하므로, 이 폴백 사다리를 그대로 가져온다.
- ONNX Runtime은 `ort` 크레이트(버전 `2.0.0-rc.7`, 참조 구현과 동일)를 쓴다.

#### 2. 오디오 재생

AVFoundation(Apple 전용) 대신 `cpal`을 쓴다. Swift의 `AudioPlaying` 프로토콜(`play(_:gain:)`, `stop()`)과 동일한 인터페이스를 Rust trait으로 유지해, 향후 다른 백엔드(Linux `alsa`/`pulseaudio`)로 교체할 여지를 남긴다.

```rust
pub trait AudioPlaying: Send + Sync {
    fn play(&self, buffer: PcmBuffer, gain: f64) -> Result<(), AudioPlayerError>;
    fn stop(&self);
}
```

#### 3. LaunchAgent/프로세스 관리 (`debrief-core`)

`std::process::Command`로 `/bin/launchctl`을 서브프로세스 실행하는 패턴은 Swift의 `Process` 패턴과 동일하게 유지한다. `RuntimeInstaller`의 로직(0.0.4에서 고친 "변경 없으면 재부트스트랩 스킵" 포함)을 그대로 포팅한다:

- 설치 전후 실행 파일 sha256 비교로 `executable_changed` 판정
- LaunchAgent plist 내용 비교로 `plist_changed` 판정 (내용이 같으면 **파일도 다시 쓰지 않는다** — mtime 변경만으로도 BTM이 재스캔하기 때문)
- `Diagnostics::status()`로 데몬이 이미 건강한지(`process == running && socket_present`) 확인
- 셋 다 "변경 없음/건강함"이면 `bootout`/`bootstrap` 자체를 건너뛴다

플랫폼 종속 부분(`launchctl` 호출, LaunchAgent plist 포맷)은 `PlatformServiceManager` trait 뒤로 감싸, 향후 systemd 구현체를 추가할 자리를 만든다. 이번 재작성에서는 macOS 구현체 하나만 만든다.

#### 4. MCP 서버 (`debrief-core`)

stdio JSON-RPC 서버 구조와 `speak`/`install` 도구 정의는 그대로 유지한다. JSON 처리는 `serde_json`을 쓴다. `speak` 도구의 `inputSchema`에 다음 필드를 추가한다.

```json
"lang": {
  "type": "string",
  "description": "BCP-47 계열 언어 코드 (ko, en, ja 등 31개 언어). 생략 시 ko.",
  "enum": ["ko", "en", "ja", "..."]
}
```

`required`는 지금과 동일하게 `["text", "voice", "speed", "volume"]`로 유지하고 `lang`은 선택 파라미터로 둔다 — 생략 시 기존 동작(한국어)과 완전히 같다.

#### 5. 설치 매니페스트/모델 다운로드 (`debrief-core`)

`InstallManifest`(소유 파일/훅 추적), `ModelManifest`(자산 URL·체크섬·검증 규칙)는 데이터 구조이므로 Rust `serde`로 그대로 옮긴다(이미 파운데이션 단계에서 완료). 검증 규칙(`revision` 정규식, `relativePath` 트래버설 방지, URL이 `/resolve/{revision}/`을 포함해야 함, sha256 형식 검증)도 동일하게 포팅했다. 모델 자산 목록(`supertonic-3`, URL·크기·체크섬)은 변경 없음 — Hugging Face 리소스는 언어와 무관하다.

**모델 다운로더**(`ModelInstaller.swift` 대응)는 아직 미구현이며, 다음 설계로 포팅한다. 동기 HTTP 클라이언트 `ureq`로 각 자산을 스테이징 디렉터리에 내려받고(`ModelInstaller.install(repair:)`의 `URLSessionModelDownloader` 대응), 다운로드한 파일의 크기·sha256을 검증한 뒤(`ModelInstallerError::ChecksumMismatch` 등, Swift와 동일 오류 종류), `renameatx_np`(Darwin 전용 원자적 교체 syscall — `libc` 크레이트로 FFI)로 최종 디렉터리와 원자적으로 맞바꾼다. `--repair` 모드에서는 기존 파일이 이미 유효(체크섬 일치)하면 재다운로드 없이 그대로 복사한다. `current.json` 포인터 파일도 같은 원자적 교체 패턴으로 갱신한다. 이 컴포넌트는 동시성 모델 절에서 정한 대로 완전히 동기(async 없음)로 구현한다.

## 배포 파이프라인

### GitHub Actions

태그 push(`v0.1.0` 등) 시 다음을 수행하는 release 워크플로를 추가한다.

```yaml
on:
  push:
    tags: ['v*']
jobs:
  release:
    runs-on: macos-15  # arm64 러너
    steps:
      - uses: actions/checkout@v4
      - run: cargo build --release --target aarch64-apple-darwin
      - run: tar -czf debrief-${{ github.ref_name }}-arm64.tar.gz -C target/aarch64-apple-darwin/release debrief
      - uses: softprops/action-gh-release@v2
        with:
          files: debrief-*.tar.gz
```

기존 `ci.yml`(PR/main push마다 `cargo test` + `cargo build --release`)은 유지하되 `swift`→`cargo` 명령으로 교체한다.

### Homebrew formula

`swift build -c release` 소스 빌드를 제거하고, Release의 tarball을 그대로 설치한다.

```ruby
class Debrief < Formula
  desc "Local TTS for Codex, Claude Code, and Grok"
  homepage "https://github.com/sparktype/debrief"
  url "https://github.com/sparktype/debrief/releases/download/v0.1.0/debrief-v0.1.0-arm64.tar.gz",
      headers: ["Authorization: Bearer #{ENV.fetch("HOMEBREW_GITHUB_API_TOKEN", "")}"]
  sha256 "..."
  depends_on arch: :arm64
  depends_on macos: :sonoma

  def install
    bin.install "debrief"
  end

  test do
    assert_match "0.1.0", shell_output("#{bin}/debrief help")
  end
end
```

`url`이 소스 아카이브(`archive/refs/tags/...`)가 아니라 Release 에셋(`releases/download/...`) tarball을 가리키는 점이 핵심 변화다. `install` 블록은 `bin.install "debrief"` 한 줄로 줄어든다 — 사용자 기계에서 Rust 툴체인이나 ONNX Runtime을 요구하지 않는다.

### ONNX Runtime 배포

`ort` 크레이트를 정적 링크 feature로 빌드해 바이너리에 ONNX Runtime을 포함시킨다. 바이너리 용량은 커지지만(추정 +20~30MB), 사용자는 별도 설치나 dylib 경로 설정이 필요 없다.

## 검증

각 컴포넌트를 완성하는 즉시 대응하는 Rust 테스트를 작성한다(TDD) — Swift 쪽에 이미 있는 테스트 스위트(`SwiftTests/DebriefCoreTests`, `DebriefIntegrationTests`)의 케이스를 1:1로 포팅하는 것을 기본으로 하고, 다국어·정적 링크처럼 새로 생기는 부분은 새 테스트를 추가한다.

- `cargo test`가 CI에서 항상 돌아간다는 것 자체가 Swift Testing 매크로 문제(Xcode 27 필요)의 해결이다.
- TTS 추론은 실제 모델 파일이 있어야 하는 통합 테스트(Swift의 `SupertonicSmokeTests`, `DEBRIEF_TEST_MODEL_DIR` 패턴)로 별도 마킹해 기본 `cargo test`에서는 건너뛴다.
- 배포 파이프라인은 태그를 실제로 눌러 GitHub Release가 만들어지고, 그 tarball로 Homebrew formula가 정상 설치되는지 실기 확인한다(이번 0.0.x 배포 때와 같은 방식).

## 리스크와 완화

| 리스크 | 완화 |
|---|---|
| Rust ONNX 추론 결과가 Swift 버전과 음질/타이밍이 다를 수 있음 | 동일 모델 자산, 동일 텐서 흐름을 쓰므로 수치적으로는 같아야 함. 실제 오디오 출력을 몇 개 텍스트로 비교 청취해 회귀 확인 |
| 정적 링크로 바이너리 용량 증가 | GitHub Release 에셋 크기 제한(2GB)에는 여유 있음. Homebrew 캐시 용량 영향은 감수 |
| `cpal` 오디오 재생이 AVFoundation과 동작이 다를 수 있음(디바이스 선택, 지연시간) | 데몬이 상주하며 반복 재생하므로 초기 통합 테스트에서 지연/끊김 여부 직접 청취 확인 |
| 다국어 도입으로 텍스트 정규화 회귀 가능성 | 기존 한국어 전용 테스트 케이스(`SupertonicTensorTests`)를 모두 포팅해 한국어 경로가 그대로 통과하는지 우선 확인 |
