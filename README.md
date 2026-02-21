# serve_app

모바일/데스크톱 앱 프로젝트의 자동 빌드 & HTTP 서빙 인프라.
git commit 시 자동으로 빌드하고, `http://localhost:8888` 에서 다운로드 가능.

- **플랫폼 무관**: Android(Gradle), Flutter, iOS(fastlane), macOS 등 `buildCommand`에 뭐든 지정 가능
- **최소 설정**: 프로젝트 루트에 `.serve_app.json` 하나 + `register.sh` 한 번 실행
- **웹 UI**: 빌드 상태, 히스토리, 실시간 로그, 수동 빌드 버튼, 아티팩트 다운로드

---

## 새 맥에 설치

### 사전 준비

```bash
# Homebrew
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Java 17 (Android/Gradle 빌드에 필요)
brew install openjdk@17

# Flutter SDK (Flutter 프로젝트만 해당)
brew install --cask flutter
```

> Python 3는 macOS에 기본 포함되어 있어 별도 설치 불필요.

### 설치 (3단계)

```bash
# 1. serve_app 클론
git clone <serve_app-repo-url> ~/Repos/serve_app

# 2. 초기 설정 (디렉토리 생성 + LaunchAgent 등록)
~/Repos/serve_app/install.sh

# 3. 앱 저장소 클론 + 등록
git clone <project-repo-url> ~/Repos/my-app
cd ~/Repos/my-app && ~/Repos/serve_app/scripts/register.sh
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
  "artifactName": "MyApp.apk"
}
```

| 필드 | 필수 | 설명 |
|------|:----:|------|
| `id` | ✓ | 프로젝트 식별자 (영문 소문자, 하이픈) |
| `name` | ✓ | 표시 이름 |
| `buildCommand` | ✓ | 빌드 명령어 (쉘에서 그대로 실행됨) |
| `buildWorkingDir` | ✓ | 빌드 실행 디렉토리 (상대경로 가능) |
| `artifactPath` | ✓ | 빌드 결과물 경로 (상대경로 가능) |
| `artifactName` | ✓ | 서빙될 파일명 |
| `watchArtifacts` | — | 로컬 빌드 감지 대상 목록 (아래 참고) |

### 2. 등록

```bash
cd /path/to/my-app
~/Repos/serve_app/scripts/register.sh
```

---

## watchArtifacts — 로컬 빌드 감지

프로젝트 저장소에서 직접 빌드한 아티팩트를 웹 UI에 별도 버튼으로 노출할 수 있다.

```json
{
  "id": "my-android-app",
  "artifactName": "MyApp-debug.apk",
  ...
  "watchArtifacts": [
    {
      "label": "Debug",
      "path": "app/build/outputs/apk/debug/app-debug.apk",
      "file": "MyApp-debug.apk"
    },
    {
      "label": "Release",
      "path": "app/build/outputs/apk/release/app-release.apk",
      "file": "MyApp-release.apk"
    }
  ]
}
```

| 필드 | 설명 |
|------|------|
| `label` | 버튼 표시 이름 (Debug / Release 등) |
| `path` | 저장소 내 아티팩트 경로 (상대경로 가능) |
| `file` | serve 디렉토리에 저장될 파일명 |

**표시 규칙**

| 버튼 | 표시 조건 | 배지 |
|------|-----------|------|
| Download `Stable` | `status=ready`이면 항상 | — |
| `{label}` `Latest` | `file`이 `artifactName`과 다른 경우 파일이 존재하면 항상 | 최신 빌드면 `Latest` |
| `{label}` `Latest` | `file`이 `artifactName`과 같은 경우 (serve_app도 빌드) | 로컬이 더 최신일 때만 |

등록 후 `/api/scan/{id}` 호출 시 저장소 파일과 마지막 serve_app 빌드를 비교해 자동 감지·복사한다.

---

## 플랫폼별 예시

### Android (Gradle)

```json
{
  "id": "my-android",
  "name": "My Android App",
  "buildCommand": "./gradlew assembleDebug",
  "buildWorkingDir": ".",
  "artifactPath": "app/build/outputs/apk/debug/app-debug.apk",
  "artifactName": "MyApp-debug.apk"
}
```

> Release 빌드도 배포하려면 debug keystore로 서명 설정 권장:
> ```kotlin
> // app/build.gradle.kts
> buildTypes {
>     release { signingConfig = signingConfigs.getByName("debug") }
> }
> ```

### Flutter

```json
{
  "id": "my-flutter",
  "name": "My Flutter App",
  "buildCommand": "flutter build apk --release",
  "buildWorkingDir": ".",
  "artifactPath": "build/app/outputs/flutter-apk/app-release.apk",
  "artifactName": "MyApp.apk"
}
```

### iOS (fastlane)

```json
{
  "id": "my-ios",
  "name": "My iOS App",
  "buildCommand": "fastlane gym --scheme MyApp --output_directory build",
  "buildWorkingDir": ".",
  "artifactPath": "build/MyApp.ipa",
  "artifactName": "MyApp.ipa"
}
```

---

## 디렉토리 구조

```
serve_app/
├── scripts/
│   ├── build.sh        # 범용 빌드 스크립트 (project-id를 인자로 받음)
│   └── register.sh     # 프로젝트 등록 + git hook 설치
├── server.py           # HTTP 서버 (정적 파일 + REST API)
├── projects/           # 등록된 프로젝트 설정 (register.sh가 자동 생성)
│   └── my-app.json
├── serve/              # HTTP 서빙 루트 (port 8888)
│   ├── index.html      # 웹 UI
│   ├── projects.json   # 전체 프로젝트 목록 (자동 갱신)
│   └── my-app/
│       ├── build-status.json
│       ├── build-history.json
│       ├── artifacts.json   # watchArtifacts 스캔 결과
│       ├── build.log        # 빌드 로그 (빌드 중 실시간 접근 가능)
│       └── MyApp.apk
├── logs/               # 빌드 로그 아카이브 (프로젝트별, 최근 10개 보관)
├── install.sh          # 최초 설치 (LaunchAgent 등록)
└── serve.sh            # HTTP 서버 수동 실행
```

---

## REST API

| 메서드 | 경로 | 설명 |
|--------|------|------|
| `GET` | `/api/scan/{id}` | 저장소 로컬 빌드 감지·복사, `artifacts.json` 갱신 |
| `POST` | `/api/build/{id}` | 빌드 수동 트리거 (build.sh 백그라운드 실행) |

---

## 관리

```bash
# HTTP 서버 재시작
launchctl kickstart -k gui/$(id -u)/com.serve_app

# HTTP 서버 중지
launchctl bootout gui/$(id -u)/com.serve_app

# 특정 프로젝트 수동 빌드
~/Repos/serve_app/scripts/build.sh my-app

# 빌드 로그 실시간 확인 (CLI)
tail -f ~/Repos/serve_app/serve/my-app/build.log

# 프로젝트 설정 재등록 (경로 변경 등)
cd /path/to/my-app && ~/Repos/serve_app/scripts/register.sh
```
