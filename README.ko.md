# CannyGit

[English](README.md) | 한국어

여러 Git 저장소와 워크트리를 한곳에서 관리하는 macOS 앱

브랜치마다 개발 서버를 띄우다 보면 어느 터미널이 어느 폴더에서 실행 중인지 헷갈리기 쉽습니다. CannyGit은 워크트리별로 터미널과 작업을 묶어 보여줍니다. 브랜치의 변경 사항을 확인하고, 빌드나 테스트를 실행하고, 사용이 끝난 워크트리를 정리할 수 있습니다.

SwiftUI와 AppKit으로 만들었으며, 내장 터미널은 [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)을 사용합니다. 현재 앱 화면은 한국어입니다.

## 할 수 있는 일

- **저장소 관리:** 폴더 선택이나 드래그 앤드 드롭으로 등록하고, 즐겨찾기와 검색으로 찾습니다. 같은 저장소의 linked worktree를 등록해도 중복으로 추가하지 않습니다.
- **워크트리 생성과 삭제:** 새 브랜치를 만들거나 기존 로컬 브랜치를 선택합니다. 삭제 전에는 변경 파일, 미추적 파일, 잠금 상태를 확인합니다.
- **Git 상태와 diff 확인:** staged, unstaged, untracked, 충돌 상태와 upstream 대비 커밋 수를 표시합니다. 파일별 읽기 전용 diff와 미추적 파일 미리 보기도 제공합니다.
- **내장 터미널:** 워크트리마다 여러 탭을 열 수 있습니다. 다른 워크트리로 이동하거나 터미널 영역을 숨겨도 세션은 유지됩니다.
- **작업 실행:** `package.json`의 scripts를 읽고 npm, pnpm, yarn, bun을 지원합니다. Rust, Go, Swift 프로젝트에는 기본 빌드와 테스트 명령을 제안합니다. 직접 명령을 등록하거나 저장소 공통 설정을 워크트리별로 바꿀 수도 있습니다.
- **실행 그룹:** 의존성을 설치하고 빌드한 뒤 서버를 실행하는 식으로 순서를 정합니다. 같은 단계의 작업은 병렬로 실행하고, 앞 단계가 성공하면 다음 단계로 넘어갑니다. 서버는 마지막 단계에 둡니다.
- **실행 현황:** 실행 중인 작업, 최근 결과, 로그, 리스닝 포트를 확인합니다. 포트나 설정한 URL을 브라우저로 열 수 있습니다.

Git commit, push, pull, PR 관리와 충돌 해결 에디터는 아직 제공하지 않습니다. 필요한 Git 작업은 내장 터미널이나 기존 도구에서 하면 됩니다.

## 빌드하고 실행하기

macOS 14 이상, 전체 Xcode, Git이 필요합니다. 빌드와 테스트는 Xcode 27.0, macOS 26.6.2, Apple Silicon 환경에서 확인했습니다. 아래 명령도 Apple Silicon 기준입니다.

프로젝트 루트에서 실행하세요.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

xcodebuild -project CannyGit.xcodeproj \
  -scheme CannyGit \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath DerivedData \
  -skipPackagePluginValidation build

open DerivedData/Build/Products/Debug/CannyGit.app
```

Metal Toolchain이 없다는 오류가 나오면 설치한 뒤 다시 빌드하세요.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -downloadComponent MetalToolchain
```

Xcode에서 `CannyGit.xcodeproj`를 열고 `CannyGit` scheme을 실행해도 됩니다. 패키지 플러그인 실행 확인이 나오면 SwiftTerm의 build-info 플러그인을 허용하세요. SwiftTerm 버전은 1.19.0으로 고정되어 있습니다.

## 처음 사용한다면

1. **저장소 등록**에서 기존 로컬 Git 저장소를 선택합니다. 사이드바에 폴더를 끌어 놓아도 됩니다.
2. 워크트리를 선택해 브랜치와 변경 상태를 확인합니다. 새 작업을 시작할 때는 **워크트리 생성**으로 별도 폴더를 만듭니다.
3. **작업** 탭에서 탐지된 명령을 확인합니다. 필요하면 실행기, 인자, 작업 디렉터리, 예상 포트를 바꾸고 실행합니다.
4. 직접 명령을 입력하려면 **터미널 열기**를 누릅니다. 여러 워크트리의 작업은 **실행 현황**에서 모아 볼 수 있습니다.
5. 작업이 끝나면 세션을 중지하고 워크트리를 삭제합니다. 워크트리를 삭제해도 브랜치는 남습니다.

명령은 탐지하는 것만으로 실행되지 않습니다. 새 워크트리에 `.env`나 의존성 폴더를 자동으로 복사하지 않으므로 프로젝트에 필요한 준비는 직접 해주세요.

### 단축키

| 단축키 | 동작        |
| ------ | ----------- |
| `⌘O`   | 저장소 등록 |
| `⌘R`   | 새로고침    |
| `⌘K`   | 명령 팔레트 |
| `⌘,`   | 설정        |

## 알아두면 좋은 점

- 창만 닫으면 터미널과 작업은 계속 실행됩니다. 앱을 정상 종료하면 앱에서 시작한 세션과 자식 프로세스를 함께 정리합니다. 강제 종료나 크래시 후 세션 복원은 지원하지 않습니다.
- Git의 ahead/behind 표시는 마지막 로컬 fetch 결과 기준입니다. 앱이 자동으로 fetch하지는 않습니다.
- 리스닝 포트가 보인다고 서버의 HTTP 응답까지 확인한 것은 아닙니다.
- 작업 로그는 실행별 5 MiB, 전체 50 MiB까지 메모리에 보관합니다. 파일로 남기려면 로그 내보내기를 사용하세요.
- 등록한 저장소와 작업 설정은 `~/Library/Application Support/CannyGit/settings.json`에 저장합니다. 작업의 환경 변수 설정에는 값을 직접 저장하지 않고, 실행 시 앱 환경에서 읽을 변수 이름을 지정합니다.
- Finder에서 실행한 앱의 `PATH`는 터미널과 다를 수 있습니다. 도구를 찾지 못하면 설정에서 Git과 셸의 경로를 확인하고 실행 진단을 해보세요.

## 테스트

프로젝트 루트에서 실행합니다. 테스트에도 전체 Xcode가 필요합니다.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

swift test

xcodebuild -project CannyGit.xcodeproj \
  -scheme CannyGit-UI \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath DerivedData \
  -skipPackagePluginValidation test
```

현재 통합 테스트 59개와 UI 시나리오 2개가 통과했습니다. 워크트리 생성과 삭제, 설정 복원, 프로세스 정리, 실행 그룹, diff 등을 검증합니다. UI 테스트는 실제 창과 키보드를 사용합니다.

실제 한글 IME 조합, VoiceOver 전체 흐름, 외장 디스크를 분리한 뒤 다시 연결했을 때의 동작은 수동 검증이 남아 있습니다. Release는 arm64/x86_64 universal 바이너리로 빌드되지만 macOS 14와 Intel 실기기에서의 실행은 아직 확인하지 않았습니다.

## Release 패키지

```sh
bash Scripts/package-release.sh
```

Release 앱을 빌드하고 `Artifacts/CannyGit-<버전>-macOS.zip`을 만듭니다. 기본값은 로컬 실행용 ad-hoc 서명입니다. 공개 배포용 Developer ID 서명과 공증은 하지 않았습니다.

## 코드 구조

```text
CannyGit/
  App/          앱 시작과 종료 처리
  Models/       저장소, 워크트리, 작업, 실행 상태
  Features/     대시보드와 각 화면
  Services/     Git, PTY 실행, 명령 탐지, 설정 저장
  Resources/    아이콘, 문자열, 라이선스 고지
CannyGitTests/   단위 테스트와 통합 테스트
CannyGitUITests/ UI 테스트
Scripts/        패키징과 개발 도구
```

Xcode 프로젝트와 `Package.swift`는 같은 소스를 사용합니다. 터미널 렌더링은 SwiftTerm에 맡기고, PTY 실행과 프로세스 수명은 앱에서 관리합니다.
