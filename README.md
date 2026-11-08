# ClawdCounter

*An unofficial macOS menu bar app that shows your Claude usage limits (5-hour / weekly) and the state of your local Claude Code sessions at a glance. Not affiliated with Anthropic; it relies on undocumented endpoints that may change or be blocked at any time. The UI is Korean only.*

Claude 사용량 한도와 로컬 Claude Code 세션 현황을 macOS 메뉴바에 보여주는 비공식 앱입니다.

## 기능

- **메뉴바 표기**: `5시간 한도 남은 시간 | [5시간 바 / 주간 바] | ● 활성 수 / ○ 비활성 수 | ✋ 응답대기`
  - 5시간 창이 활성이 아니면 남은 시간 자리에 `–`가 표시되고, 5시간 한도 자체가 없으면 주간 바만 표시됩니다.
  - 응답대기 세션이 있을 때만 `✋`가 붙고, 2개 이상이면 개수가 함께 표시됩니다.
  - 로그아웃 상태에서는 `로그인 필요`, 만료되면 `다시 로그인 필요`가 표시됩니다.
- **사용률 4단계 색**: 바와 드롭다운의 색은 화면에 표시되는 정수 퍼센트(반올림) 기준입니다.

  | 사용률 | 색 |
  |---|---|
  | 0–49% | 초록 |
  | 50–79% | 노랑 |
  | 80–94% | 주황 |
  | 95% 이상 | 빨강 |

- **드롭다운** (구분선으로 구획)
  1. 한도: 5시간 / 주간 / Fable. 바, 퍼센트, 남은 시간. API 응답에 해당 한도가 없으면 그 줄은 표시하지 않습니다.
  2. 크레딧: 추가 사용(크레딧) 금액. 총량을 아는 경우 `사용액 / 총량`.
  3. 세션: 상태별 헤더와 세션명 목록(상태별 최대 8개, 초과분은 `외 N개`).
  4. Claude 로그인 / 로그아웃, 설정(로그인 시 자동 실행, 사용량 갱신 주기 1·2·5분).
  5. 종료.
- **세션 상태 3종**: ● 활성(초록) / 응답대기(메뉴바는 ✋, 드롭다운은 노랑 ●) / ○ 비활성. 실행 중인 서브에이전트는 활성 세션에 1개씩 더해지고 `↳ 설명`으로 나열됩니다.
- **세션명 클릭**: 그 세션이 실행 중인 앱(터미널, VS Code, Claude 데스크탑 등)을 앞으로 가져옵니다.

## 주의 / 면책

- **Anthropic과 무관한 비공식 앱**입니다. Anthropic이 만들거나 보증하지 않습니다.
- 사용량 조회 API(`api.anthropic.com/api/oauth/usage`)와 OAuth 클라이언트 ID는 설치된 Claude Code에서 확인한 **비공식 값**입니다. 문서화된 공개 API가 아니므로 **언제든 바뀌거나 차단될 수 있고**, 그렇게 되면 앱이 동작하지 않을 수 있습니다.
- 이 앱을 쓰다 생기는 계정 관련 문제에 대해 보증하거나 책임지지 않습니다(LICENSE 참조).

## 요구 사항

- macOS 14 이상
- Xcode와 Swift 6 툴체인 (`swift-tools-version: 6.0`)

## 설치 / 빌드

```sh
git clone https://github.com/wooklab/clawdcounter.git
cd clawdcounter
scripts/build_app.sh        # 결과: build/ClawdCounter.app
open build/ClawdCounter.app
```

앱은 메뉴바 전용(`LSUIElement`)이라 Dock 아이콘이 없습니다.

### 첫 실행 경고

빌드 스크립트는 임시(ad-hoc) 서명(`codesign --sign -`)만 합니다. 직접 빌드한 앱은 보통 경고 없이 실행되지만, 다른 곳에서 내려받았거나 압축해 옮긴 앱은 Gatekeeper 경고가 뜰 수 있습니다. 그럴 때는 다음 중 하나를 쓰세요.

- Finder에서 `build/ClawdCounter.app`을 우클릭 → **열기**
- 또는 `xattr -dr com.apple.quarantine build/ClawdCounter.app`

`xattr` 명령은 **본인이 직접 빌드한 앱에만** 사용하세요. 출처를 모르는 앱에 쓰면 안 됩니다.

### 키체인 확인창

로그인하면 토큰(액세스/리프레시)을 앱 전용 키체인 항목 `ClawdCounter-credentials`에 저장합니다. 앱을 다시 빌드하거나 업데이트하면 임시 서명이 달라져 키체인 접근 확인창이 다시 뜰 수 있으며, 이때 **항상 허용**을 선택하면 됩니다.

## 사용 방법

1. 앱을 실행하면 메뉴바에 `로그인 필요`가 표시됩니다.
2. 메뉴바 항목을 클릭하고 **Claude 로그인**을 선택합니다. 기본 브라우저가 열리고, 로그인을 마치면 앱이 자동으로 사용량을 불러옵니다.
3. 로컬 콜백 서버를 열 수 없으면 브라우저에서 표시되는 코드를 앱에 붙여넣는 방식으로 전환됩니다.
4. 사용량은 기본 1분마다 갱신되며(설정에서 1·2·5분), 메뉴를 열 때도 갱신합니다.

## 개인정보

**읽는 로컬 파일** (모두 읽기 전용)

- `~/.claude/sessions/*.json`: 세션 상태(`status`), 이름, 작업 디렉터리, 세션 ID 등
- `~/.claude/projects/*/<sessionId>/subagents/*.meta.json`: 서브에이전트 설명과 종료 여부
- 같은 위치의 서브에이전트 `jsonl` 파일은 **수정 시각만** 확인하고 내용은 읽지 않습니다.

**네트워크**

- 로그인: `claude.com`(브라우저에서 인증 페이지 열기), `platform.claude.com`(토큰 발급/갱신/폐기)
- 사용량 조회: `api.anthropic.com`
- 제3자 서버나 분석/원격 측정 전송은 없습니다.

**자격증명**

- Claude Code의 자격증명(키체인 항목, `~/.claude`의 인증 정보)은 읽거나 쓰지 않습니다. 앱이 자체 OAuth 로그인으로 받은 토큰만 사용합니다.
- **로그아웃**하면 앱 토큰을 키체인에서 삭제하고, 서버에 토큰 폐기를 시도합니다(실패해도 로컬 삭제는 유지).

**앱이 디스크에 쓰는 것**

- `~/Library/Application Support/ClawdCounter/last_usage_raw.json`: 디버깅용으로 **마지막 사용량 API 응답 원문**을 덮어씁니다(권한 0600). 개인 사용량 정보가 들어 있으니 공유하지 마세요. 토큰과 헤더는 저장하지 않습니다.
- 사용량 갱신 주기 설정(UserDefaults).

## 알려진 한계

- **Max 5x 계정 한 개로만 검증**했습니다. 다른 요금제(Pro, Team, Enterprise, API 등)는 검증하지 못했습니다.
- Fable 한도와 크레딧(추가 사용)이 **활성화된 상태의 응답 형태는 확인하지 못했고 추정**으로 구현했습니다. 실제로 본 응답에서는 둘 다 비활성이었습니다.
- 세션 초기화 사용권(티켓) 개수는 실제 응답에서 필드를 찾지 못해 **지원하지 않습니다**.
- **응답대기** 상태는 `claude` 바이너리 분석으로 알아낸 값(`waiting`)에 기반하며, 실제 세션에서 확인하지는 못했습니다.
- 세션명 클릭은 **앱 단위로 전면화**할 뿐 앱 안의 특정 탭/창/세션을 고르지는 않습니다. tmux처럼 부모 프로세스 사슬이 끊기는 경우는 앱을 찾지 못합니다.
- UI 문자열은 한국어만 지원합니다.
- 서명하지 않은(임시 서명) 로컬 빌드만 지원하며 배포용 바이너리는 제공하지 않습니다.

## 개발

```sh
swift test                  # 전체 단위 테스트
swift run RenderPreview     # 메뉴바 이미지/드롭다운 PNG 렌더 -> build/preview/
```

`RenderPreview`는 프로젝트 루트에서 실행해야 하며, 라이트/다크별 PNG와 메뉴 구조 텍스트(`menus.txt`)를 `build/preview/`에 만듭니다.

### `--probe-usage` 진단 플래그

```sh
build/ClawdCounter.app/Contents/MacOS/ClawdCounter --probe-usage
```

로그인된 상태에서 사용량 API의 쿼리 변형 응답들을 `~/Library/Application Support/ClawdCounter/probe/`에 저장합니다. 변형 쿼리는 Claude Code 바이너리에서 본 비공식 값으로 의미가 확인되지 않았습니다. **저장되는 응답에는 개인 사용량 정보가 담기니, 이슈에 올리기 전에 반드시 가리세요.**

구조는 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)를 참고하세요.

## 기여

이슈와 PR을 환영합니다. 특히 **다른 요금제 계정의 (개인정보를 가린) 사용량 API 응답 샘플**이 있으면 크게 도움이 됩니다. 값(퍼센트, 금액, 날짜, 식별자)은 가리고 키 구조만 남겨 주세요.

## 라이선스

[MIT License](LICENSE)
