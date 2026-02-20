# serve_app

모바일 앱 프로젝트들의 APK 자동 빌드 & HTTP 서빙 인프라.
git commit 시 자동으로 APK를 빌드하고, `http://localhost:8888` 에서 다운로드 가능.

---

## 새 맥에 설치

### 사전 준비

```bash
# Homebrew
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Java 17 (Android 빌드에 필요)
brew install openjdk@17

# Flutter SDK (이미 설치되어 있으면 생략)
brew install --cask flutter
```

> Python 3는 macOS에 기본 포함되어 있어 별도 설치 불필요.

### 설치 (3단계)

```bash
# 1. serve_app 클론 (경로 고정 필수 — git hook이 이 경로를 직접 참조)
git clone <serve_app-repo-url> ~/Repos/serve_app

# 2. 초기 설정 (디렉토리 생성 + LaunchAgent 등록)
~/Repos/serve_app/install.sh

# 3. 앱 저장소 클론 + 등록
git clone <project-repo-url> ~/Repos/logger
cd ~/Repos/logger && ~/Repos/serve_app/scripts/register.sh
```

완료. 이후 `git commit` 하면 자동 빌드 → `http://localhost:8888` 에서 확인.

> **경로 주의**: serve_app은 반드시 `~/Repos/serve_app`에 클론해야 합니다.
> `register.sh`가 설치하는 git hook이 이 절대 경로를 기록합니다.
> 다른 경로를 사용하려면 클론 후 `register.sh`를 다시 실행하면 됩니다.

---

## 새 앱 프로젝트 추가

### 1. 프로젝트 루트에 `.serve_app.json` 추가

```json
{
  "id": "my-app",
  "name": "My App",
  "buildCommand": "flutter build apk --release",
  "buildWorkingDir": "platforms/flutter",
  "artifactPath": "platforms/flutter/build/app/outputs/flutter-apk/app-release.apk",
  "apkName": "MyApp.apk"
}
```

| 필드 | 설명 |
|------|------|
| `id` | 프로젝트 식별자 (영문 소문자, 하이픈) |
| `name` | 표시 이름 |
| `buildCommand` | 빌드 명령어 |
| `buildWorkingDir` | 빌드 실행 디렉토리 (프로젝트 루트 기준 상대경로 가능) |
| `artifactPath` | 빌드 결과물 경로 (프로젝트 루트 기준 상대경로 가능) |
| `apkName` | 서빙될 파일명 |

### 2. 등록

```bash
cd /path/to/my-app
~/Repos/serve_app/scripts/register.sh
```

---

## 디렉토리 구조

```
serve_app/
├── scripts/
│   ├── build.sh        # 범용 빌드 스크립트 (project-id를 인자로 받음)
│   └── register.sh     # 프로젝트 등록 + git hook 설치
├── projects/           # 등록된 프로젝트 설정 (register.sh가 자동 생성)
│   └── logger.json
├── serve/              # HTTP 서빙 루트 (port 8888)
│   ├── index.html      # 웹 UI
│   ├── projects.json   # 전체 프로젝트 목록 (build.sh가 자동 갱신)
│   └── logger/
│       ├── build-status.json
│       ├── build-history.json
│       └── RaceLogger.apk
├── logs/               # 빌드 로그 (프로젝트별)
├── install.sh          # 최초 설치
└── serve.sh            # HTTP 서버 수동 실행
```

---

## 관리

```bash
# HTTP 서버 재시작
launchctl kickstart -k gui/$(id -u)/com.serve_app

# HTTP 서버 중지
launchctl bootout gui/$(id -u)/com.serve_app

# 특정 프로젝트 수동 빌드
~/Repos/serve_app/scripts/build.sh logger

# 빌드 로그 실시간 확인
tail -f ~/Repos/serve_app/logs/logger/build-*.log
```
