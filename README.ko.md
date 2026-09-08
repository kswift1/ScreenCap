<p align="center">
  <img src="assets/icon.png" width="160" alt="ScreenCap icon">
</p>

# ScreenCap

[English](README.md) · **한국어**

CleanShot X를 벤치마킹한 macOS용 스크린샷·화면 녹화 앱입니다. Swift(AppKit + SwiftUI)와 ScreenCaptureKit으로 만들었습니다.

## 기능

- **캡처** — 메뉴바나 전역 단축키로 전체 화면, 영역(드래그), 윈도우(호버 후 클릭)를 캡처합니다. 앞에 있는 앱의 포커스를 빼앗지 않아 캡처된 창이 비활성 상태로 흐려지지 않습니다. Retina 대응, 마우스 커서 포함 여부 선택 가능.
- **All-in-One** — ⇧⌘8로 오버레이 하나를 띄우고 하단 툴바(Area · Window · Fullscreen · Pin · Record · Text · Scroll)에서 모드를 바꿉니다. 클릭 또는 A/W/F/P/R/T/S 키(또는 1~7)로 전환하며, 마지막에 쓴 모드를 기억합니다.
- **OCR** — ⇧⌘7로 텍스트 위를 드래그하면(또는 윈도우를 클릭하면) 줄바꿈을 유지한 일반 텍스트로 클립보드에 복사됩니다. 한국어·영어·일본어·중국어를 인식하고, QR 코드도 읽어 URL이면 Open 버튼을 보여줍니다.
- **핀** — ⇧⌘4로 영역(또는 윈도우)을 캡처하면 그 자리에 모든 앱과 Space 위에 떠 있는 고정 창이 됩니다. 채팅이나 문서를 옆에 두고 참고할 때 유용합니다. 드래그로 이동, 가장자리에서 크기 조절, 스크롤로 투명도 조절, Esc 또는 ✕로 닫기. 잠금(⌘L 또는 메뉴)을 걸면 클릭이 통과되고 움직이지 않습니다. ⌘+스크롤이나 핀치로 25~400% 확대·축소, 더블클릭으로 원래 크기, 화살표 키로 미세 이동, ⇧⌘9로 모든 핀 숨기기/표시. 메뉴바의 Pins 서브메뉴에서 목록 확인, 잠금 해제, 마지막에 닫은 핀 다시 열기가 됩니다.
- **Quick Access 오버레이** — 캡처 결과가 화면 좌하단에 쌓입니다. 호버하면 복사 / 저장 / 주석 / 핀 / GIF 버튼이 나오고, 썸네일을 다른 앱으로 바로 드래그할 수 있으며, 그대로 두면 자동으로 사라집니다. 카드 위에서 키 하나로 동작합니다: C 복사, S 저장, ⇧S 다른 이름으로 저장, E 주석, P 핀, G GIF, O 열기, F Finder에서 보기, ⌫ 닫기, ⌘⌫ 모두 닫기.
- **주석 편집기** — 화살표(직선·곡선), 선, 사각형, 원, 펜, 형광펜, 텍스트, 픽셀화(모자이크), 블랙아웃, 스포트라이트, 자르기, 번호 카운터. 배경 도구로 여백·둥근 모서리·그림자·단색/그라데이션/메시 배경을 넣어 공유용 이미지를 만듭니다. "Detect sensitive text"는 OCR로 이메일·전화번호·IP·API 키를 찾아 픽셀화를 제안합니다. 실행 취소/다시 실행, 선택 도구로 이동, 도구 단축키(A, L, R, O, P, H, T, B, K, N, S, C, V).
- **화면 녹화** — 영역이나 윈도우를 H.264 `.mp4`로 녹화하고(시스템 오디오 선택 가능), Quick Access에서 반복 재생 GIF로 변환합니다.

기본 단축키 (설정 → Shortcuts에서 변경):

| 동작 | 단축키 |
| --- | --- |
| 전체 화면 캡처 | ⇧⌘1 |
| 영역 캡처 | ⇧⌘2 |
| 윈도우 캡처 | ⇧⌘3 |
| 영역 핀 고정 (참고용 플로팅 창) | ⇧⌘4 |
| 화면 녹화 (시작/정지) | ⇧⌘5 |
| 마지막 캡처 열기 | ⇧⌘6 |
| 텍스트 복사 (OCR) | ⇧⌘7 |
| All-in-One | ⇧⌘8 |
| 핀 숨기기/표시 | ⇧⌘9 |
| 스크롤 캡처 | ⇧⌘0 |
| 캡처 히스토리 | (메뉴바; 기본 미지정) |

⇧⌘3/4/5는 macOS 기본 스크린샷 단축키와 겹치며 시스템 쪽이 우선합니다. 시스템 설정 → 키보드 → 키보드 단축키 → 스크린샷에서 꺼 주세요. ScreenCap의 Shortcuts 탭이 충돌을 감지해 경고하고 해당 설정 화면으로 연결해 줍니다.

## 요구 사항

- macOS 15 (Sequoia) 이상 — `SCScreenshotManager`, `SCRecordingOutput`을 사용합니다.
- Xcode 26, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
- 화면 녹화 권한 (시스템 설정 → 개인정보 보호 및 보안 → 화면 및 시스템 오디오 녹음). 권한을 켠 뒤 앱을 다시 실행하세요.

## 빌드 및 실행

```sh
./scripts/run.sh          # xcodegen + xcodebuild (Debug) + 실행
```

기본 빌드는 ad-hoc 서명이라 다시 빌드할 때마다 macOS가 화면 녹화 권한을 다시 물을 수 있습니다. 권한을 유지하려면 `scripts/local.env.example`을 `scripts/local.env`로 복사하고 Apple Developer 팀 ID를 넣어 주세요. 이 파일은 git에서 제외되며 `scripts/build.sh`가 xcodebuild에 전달합니다. Xcode에서 직접 빌드할 때는 타겟의 Signing 탭에서 팀을 고르면 됩니다.

`./scripts/install.sh`는 Release로 빌드해 `/Applications`에 복사하고(Spotlight·Launchpad에서 검색되도록) 거기서 실행합니다. `scripts/build.sh`는 빌드만 합니다. `.app`은 `build/Build/Products/Debug/`에 생성됩니다. Xcode에서 작업하려면 `xcodegen generate`를 실행한 뒤 `ScreenCap.xcodeproj`를 여세요. 프로젝트 파일은 git에서 제외되어 있고 `project.yml`이 원본입니다.

개발용 실행 인자:

```sh
ScreenCap.app/Contents/MacOS/ScreenCap --open-editor path/to/image.png   # 주석 편집기를 바로 열기
ScreenCap.app/Contents/MacOS/ScreenCap --debug-overlay                    # 선택 오버레이를 띄우고 결과를 로그로 출력
```

## 프로젝트 구조

```
ScreenCap/
  App/          진입점, 앱 델리게이트, 메뉴바 아이템, 메인 메뉴
  Capture/      ScreenCaptureKit 엔진, 윈도우 목록, 선택 오버레이, 코디네이터, 핀 창
  Recording/    SCStream 녹화기, 화면 위 녹화 컨트롤, GIF 내보내기
  QuickAccess/  좌하단 썸네일 스택 (NSPanel + SwiftUI)
  Editor/       주석 모델, 공용 CG 렌더러, AppKit 캔버스, 편집기 창
  Settings/     UserDefaults 기반 환경설정과 설정 창
  Hotkeys/      Carbon RegisterEventHotKey 래퍼와 단축키 녹화 UI
  Support/      파일 저장, 클립보드, 권한, OCR, 확장
```

설계 메모:

- 오버레이와 Quick Access는 **non-activating `NSPanel`** 이라 ScreenCap이 포커스를 가져가지 않고, 캡처 대상 앱이 흐려지지 않습니다.
- ScreenCap의 모든 창은 `SCContentFilter`에서 제외되므로 오버레이, 녹화 프레임, 녹화 컨트롤이 결과물에 찍히지 않습니다.
- 주석은 화면 캔버스와 내보내기 이미지 모두 하나의 Core Graphics 코드(`AnnotationRenderer`)로 그립니다. 좌표는 y가 아래로 증가하는 이미지 픽셀 기준입니다.

## 릴리스

### 릴리스 설치하기

1. [Releases 페이지](https://github.com/kswift1/ScreenCap/releases)에서 `ScreenCap-<version>.dmg`를 내려받습니다. 같은 앱의 `.zip`과 SHA-256 체크섬도 함께 올라갑니다.
2. dmg를 열고 **ScreenCap**을 옆에 있는 **Applications** 바로가기로 드래그한 뒤 디스크 이미지를 추출합니다.
3. 응용 프로그램 폴더에서 ScreenCap을 실행합니다. 릴리스는 Developer ID 인증서로 서명하고 Apple 공증(notarization)을 받았기 때문에 Gatekeeper가 우클릭 우회 없이 바로 열어 줍니다. ScreenCap은 메뉴바에만 나타납니다(Dock 아이콘 없음).
4. 첫 캡처 때 macOS가 **화면 녹화** 권한을 요청합니다. 시스템 설정 → 개인정보 보호 및 보안 → 화면 및 시스템 오디오 녹음에서 허용한 뒤 ScreenCap을 종료하고 다시 실행하세요. 마이크를 켜고 녹화하면 마이크 권한도 같은 방식으로 요청합니다.

### 릴리스 만들기 (메인테이너)

`scripts/release.sh`가 빌드·서명·공증·패키징을 한 번에 처리합니다. Xcode 명령줄 도구, 키체인에 들어 있는 **Developer ID Application** 인증서, 그리고 `scripts/local.env`(git 제외, `scripts/local.env.example`을 복사해서 시작)의 두 키가 필요합니다.

| 키 | 의미 |
| --- | --- |
| `DEVELOPMENT_TEAM` | Developer ID 인증서를 소유한 팀 ID (`security find-identity -v -p codesigning`으로 확인). |
| `NOTARY_PROFILE` | `notarytool` 키체인 프로필 이름. `xcrun notarytool store-credentials "<이름>" --apple-id … --team-id … --password <앱 암호>`로 한 번만 만들어 둡니다. |

```sh
scripts/release.sh 1.2.0 --dry-run   # 빌드 + 서명 + zip + dmg까지만. 공증·커밋·태그 없음
scripts/release.sh 1.2.0             # 실제 릴리스
```

스크립트는 semver를 검증하고 `project.yml`의 `CFBundleShortVersionString`을 설정하며 `CFBundleVersion`을 1 올린 뒤, Developer ID 아이덴티티·hardened runtime·보안 타임스탬프로 Release를 빌드합니다. 이어서 앱을 zip으로 묶어(`ditto`) `notarytool --wait`로 제출하고 티켓을 스테이플하며, dmg(앱 + Applications 심볼릭 링크, 볼륨 이름 "ScreenCap")를 만들어 서명·공증·스테이플하고, SHA-256 합계와 이전 태그 이후의 git log로 채운 `RELEASE_NOTES.md` 초안을 `dist/`에 씁니다. 마지막으로 버전 변경을 커밋하고 주석 태그 `v<version>`을 만들며(이미 있으면 중단), 노트를 다듬은 뒤 실행할 `git push`와 `gh release create … --notes-file dist/RELEASE_NOTES.md` 명령을 출력합니다. 실제 실행은 작업 트리가 깨끗하지 않으면 시작하지 않고, `--dry-run`은 경고만 하고 끝날 때 `project.yml`을 원래대로 되돌립니다. 평소의 `scripts/build.sh` / `run.sh` 빌드는 그대로 ad-hoc 서명입니다.

## 라이선스

MIT — [LICENSE](LICENSE) 참고.
