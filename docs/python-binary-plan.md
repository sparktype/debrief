# Chorus — Python 단일 바이너리 전환 계획

작성일: 2026-07-10  
목적: `.venv` 없이 `chorus` 단일 실행파일로 설치·배포  
전제: Go 전환 취소 → Python 유지, mlx (Apple Metal) 의존성 보존

---

## 1. 핵심 제약: mlx + Metal dylib

```
mlx/core.cpython-313-darwin.so
  └─ @rpath/libmlx.dylib   ← Apple Metal GPU 커널 로더
     └─ mlx/lib/*.metallib ← Metal GPU 커널 바이너리 (~178 MB)
```

- `.metallib`은 Metal API가 **파일 경로 기반**으로 로드 → 런타임에 실제 경로 필요
- `.dylib`는 `@rpath` 방식 → 실행파일 위치 기준으로 찾음
- 어떤 패키징 도구든 이 두 파일을 **올바른 상대 경로**로 배치해야 GPU 동작

---

## 2. 도구 비교 결론

| 도구 | 단일파일 | mlx/dylib | Python 3.13 | cold start | 평가 |
|------|---------|-----------|------------|------------|------|
| **PyInstaller --onefile** | 실질 불가 | @rpath 수동 패치 필요 | 지원 | 5~15초/실행 | ✗ |
| **PyInstaller --onedir** | 디렉토리 | @rpath 수동 패치 필요 | 지원 | 빠름 | △ |
| **Nuitka --onefile** | 가능 | install_name_tool 수작업 | 실험적 | 빠름 | △ |
| **PyApp** | 가능 | pip 위임(초기 다운로드) | 가능 | 초기 느림 | ✗ (오프라인 불가) |
| **shiv / pex** | 불가 | 시스템 설치 필요 | 가능 | 중간 | ✗ |
| **Briefcase** | .app 번들 | 가능 | 가능 | 보통 | ✗ (CLI 부적합) |
| **conda-pack** | 디렉토리 | 자동 포함 | 가능 | 빠름 | △ |
| **→ PyInstaller --onedir + install script** | 디렉토리 zip | 가능 | 지원 | 빠름 | **✓ 현실적 최선** |

### 결론: 진정한 단일 실행파일은 불가

mlx의 `@rpath/libmlx.dylib` + `.metallib` (~178 MB) 때문에  
**어떤 도구도 완전한 단일 파일로 MLX GPU를 작동시킬 수 없음**.

---

## 3. 채택 전략: PyInstaller --onedir + 설치 스크립트

### 배포 구조

```
chorus-1.0.0-macos-arm64.tar.gz
└── chorus/
    ├── chorus            ← 실행파일 (PyInstaller 생성)
    ├── _internal/        ← .so + .dylib + .metallib (자동)
    │   ├── mlx/
    │   │   ├── core.cpython-313-darwin.so
    │   │   └── lib/
    │   │       ├── libmlx.dylib
    │   │       └── *.metallib
    │   ├── supertonic_mlx/
    │   ├── sounddevice/
    │   └── ...
    └── install.sh        ← /usr/local/bin 심링크 생성
```

- 사용자는 `tar xf chorus-*.tar.gz && chorus/install.sh` 한 번으로 완료
- `.venv` / `pip install` 불필요
- `hooks/stop.sh` → `/usr/local/bin/chorus hook` 호출

### PyInstaller 주요 옵션

```bash
pyinstaller \
  --name chorus \
  --onedir \
  --collect-all mlx \
  --collect-all mlx_metal \
  --collect-all supertonic_mlx \
  --collect-all mlx_whisper \
  --collect-all sounddevice \
  --collect-all soundfile \
  --collect-all tokenizers \
  --collect-all safetensors \
  --hidden-import uvloop \
  --hidden-import uvicorn.lifespan.on \
  --hidden-import fastapi \
  --add-data "voice-map.json:." \
  --add-data "assets:assets" \
  hook_voice/__main__.py
```

### mlx metallib 경로 패치 (필수)

`hook_voice/__main__.py` 진입점 최상단:

```python
import sys, os
if getattr(sys, 'frozen', False):
    # PyInstaller frozen 환경에서 MLX Metal 커널 경로 수동 설정
    _mlx_lib = os.path.join(sys._MEIPASS, 'mlx', 'lib')
    os.environ.setdefault('MLX_METAL_PATH', _mlx_lib)
```

`tts_server/supervisor.py` 동일 패치 적용.

---

## 4. 대안 비교: conda-pack

```bash
conda create -n chorus python=3.13
conda run -n chorus pip install -e .
conda pack -n chorus -o chorus-env.tar.gz
```

- 결과물: 디렉토리 tarball (~600 MB) → `source activate` 후 실행
- 장점: mlx/dylib 자동 포함, rpath 문제 없음
- 단점: 배포 크기 크고, `conda` 사용자 환경 오염 가능

**PyInstaller --onedir가 더 깔끔하므로 conda-pack은 보조 수단.**

---

## 5. 구현 단계 체크리스트

### Phase 1 — 빌드 환경 구성 (1일)

- [ ] `pip install pyinstaller` (프로젝트 .venv에)
- [ ] `chorus.spec` 파일 작성 (위 옵션 포함)
- [ ] `frozen` 환경 MLX Metal 경로 패치 코드 추가 (`__main__.py`, `supervisor.py`)
- [ ] `multiprocessing.freeze_support()` 호출 추가 (supervisor)

### Phase 2 — 빌드 검증 (1일)

- [ ] `pyinstaller chorus.spec` 실행
- [ ] `dist/chorus/chorus hook` — CLI 동작 확인
- [ ] `dist/chorus/chorus server` — FastAPI 서버 기동 확인 (`curl localhost:7777/health`)
- [ ] `dist/chorus/chorus voice test` — MLX GPU TTS 동작 확인 (metallib 로드 검증)
- [ ] STT toggle 동작 확인 (sounddevice + mlx_whisper)

### Phase 3 — 패키징 및 install.sh (0.5일)

- [ ] `tar czf chorus-$(git describe --tags)-macos-arm64.tar.gz dist/chorus/`
- [ ] `dist/chorus/install.sh` 작성:
  ```bash
  #!/bin/zsh
  ln -sf "$(pwd)/chorus" /usr/local/bin/chorus
  echo "chorus 설치 완료: $(chorus --version)"
  ```
- [ ] `server.sh` 수정: `.venv/bin/python -m ...` → `chorus ...`
- [ ] `hooks/stop.sh` 등 모든 hook 스크립트 수정: `chorus hook` 직접 호출
- [ ] `install.sh` (전역 설정 등록 스크립트) 수정

### Phase 4 — 회귀 테스트 (0.5일)

- [ ] Hook 체인 전체 동작 확인 (Stop / SubagentStop / PreToolUse 등)
- [ ] HUD 레이블 (`chorus hud-label`) 확인
- [ ] 세션 다이제스트 (`chorus digest`) 확인
- [ ] launchd plist 수정 — supervisor 대신 `chorus server` 기동

---

## 6. 기대 효과

| 항목 | 현재 (.venv) | 변환 후 (onedir) |
|------|-------------|----------------|
| hook 기동 지연 | ~200ms (Python 인터프리터 + import) | ~80ms (frozen, import 최적화) |
| 설치 절차 | `setup-tts.sh` (복잡) | `tar xf` + `install.sh` (2단계) |
| 배포 크기 | .venv ~800MB+ | dist/ ~350MB (압축 시 ~120MB) |
| Python 버전 의존 | 시스템 Python 필요 | 자체 번들 Python 포함 |
| pip 의존 | 설치/업데이트 pip 필요 | 불필요 |

---

## 7. 미결 사항

1. **서버 모드 진입점**: `chorus server` 서브커맨드 추가 필요 (현재 supervisor.py 직접 실행 방식)  
   → `__main__.py`에 `elif subcommand == "server": run_supervisor()` 추가

2. **버전 정보**: `chorus --version` 출력용 버전 상수 (`__version__`) 추가

3. **pyinstaller hook 파일**: mlx, supertonic_mlx 미지원 hook이 있으면 커스텀 `hook-mlx.py` 작성 필요  
   → `pyinstaller --additional-hooks-dir=.pyinstaller_hooks/`

4. **코드 서명**: 배포 시 macOS Gatekeeper 대응  
   → 개인 사용 목적이면 `xattr -d com.apple.quarantine chorus` 안내로 충분

5. **빌드 CI**: GitHub Actions macOS arm64 runner에서 자동 빌드 가능  
   (단, `mlx_metal` 등 Apple Silicon 전용 패키지는 arm64 runner 필수)
