# 아키텍처

ClawdCounter는 SwiftPM 패키지(Swift 6, macOS 14+)로, 라이브러리 타깃 5개와 실행 타깃 2개로 이루어집니다. 외부 의존성은 없습니다.

## 모듈

| 모듈 | 종류 | 책임 | 의존 |
|---|---|---|---|
| `CoreModels` | 라이브러리 | 공유 값 타입(`UsageSnapshot`, `LimitWindow`, `CreditUsage`, `SessionCounts`, `SessionRef`, `AuthState`), 프로토콜(`TokenProviding`, `AuthManaging`, `UsageProviding`, `SessionMonitoring`), 멀티캐스트 헬퍼 `Broadcaster` | 없음 |
| `SessionsKit` | 라이브러리 | `~/.claude/sessions` 감시와 상태 분류, 서브에이전트 판정, 프로세스 생존/조상 탐색 | `CoreModels` |
| `AuthKit` | 라이브러리 | OAuth(PKCE) 로그인, 로컬 콜백 서버, 토큰 갱신/폐기, 키체인 저장 | `CoreModels` |
| `UsageKit` | 라이브러리 | 사용량 API 호출, 응답 -> `UsageSnapshot` 매핑, 진단용 프로브 | `CoreModels` |
| `MenuBarUI` | 라이브러리 | 상태바 이미지 렌더러, 드롭다운 `NSMenu` 빌더, 시간 포맷, 사용률 단계 색 | `CoreModels` |
| `ClawdCounter` | 실행 | 앱 본체: `AppDelegate`/`AppModel`, 사용량 폴러, 설정 창, 수동 코드 입력창, 세션 앱 전면화 | 위 5개 전부 |
| `RenderPreview` | 실행 | 개발용: `MenuBarUI`를 모의 데이터로 그려 PNG/텍스트로 출력 | `CoreModels`, `MenuBarUI` |

Kit 모듈끼리는 서로 의존하지 않고 `CoreModels`의 타입/프로토콜로만 연결됩니다. 합치는 곳은 `ClawdCounter` 실행 타깃뿐입니다.

```
              CoreModels
   ┌─────────┬───┴─────┬──────────┐
SessionsKit  AuthKit  UsageKit  MenuBarUI
   └─────────┴───┬─────┴──────────┘
            ClawdCounter        (RenderPreview 는 CoreModels + MenuBarUI 만 사용)
```

## 데이터 흐름

```
~/.claude/sessions/<pid>.json ──┐
~/.claude/projects/*/<sid>/     ├─> SessionMonitor ──> SessionCounts ──┐
   subagents/agent-*.meta.json ─┘   (FSEvents + 재스캔)                │
                                                                       ▼
OAuth 로그인 ─> 키체인(앱 전용) ─> AuthManager ─> UsageClient ─> UsageSnapshot ─> AppModel ─┬─> StatusItemRenderer (메뉴바 이미지)
                                  (토큰 제공)   (GET usage)    (UsageMapping)                └─> MenuBuilder (드롭다운, 메뉴 열 때 생성)
```

- **세션**: `SessionMonitor`가 세션 파일과 서브에이전트 메타를 읽어 `SessionCounts`(개수 + 상태별 `SessionRef` 목록)를 `Broadcaster`로 내보냅니다. `AppDelegate`가 이를 구독해 `AppModel.counts`에 넣습니다.
- **사용량**: `AuthManager`가 `TokenProviding`으로 유효한 액세스 토큰(필요 시 갱신)을 주고, `UsageClient`가 사용량 API를 호출해 `UsageMapping`으로 `UsageSnapshot`을 만듭니다. `UsagePoller`(앱 타깃)가 주기 실행과 백오프를 맡고 결과를 `AppModel.usage`에 넣습니다.
- **표시**: `AppModel`의 `usage`/`counts`/`authState` 중 하나라도 바뀌면 `onChange`로 `StatusItemRenderer.image(...)`를 다시 그려 상태바 버튼에 설정합니다. 드롭다운은 메뉴를 열 때(`menuNeedsUpdate`) `MenuBuilder.buildMenu(...)`로 새로 만듭니다. 남은 시간 표기가 변하므로 30초마다도 다시 그립니다.
- 인증 상태가 `signedIn`이 되면 폴링을 시작하고, 그 외에는 폴링을 멈추고 사용량 값을 비웁니다.

## 세션 상태 매핑

세션 파일(`<pid>.json`)의 `status` 문자열을 `StatusMapping`이 분류합니다. 값이 바뀌면 이 매핑만 고치면 됩니다.

| `status` | 분류 | 표시 |
|---|---|---|
| `busy`, `shell` | 활성 | ● 초록 |
| `waiting` | 응답대기 | 메뉴바 ✋ / 드롭다운 노랑 ● |
| `idle` | 비활성 | ○ |
| 그 외, 누락 | 비활성(경고 로그 1회) | ○ |

이 값들은 설치된 `claude` 바이너리에서 확인한 것입니다. 특히 `waiting`은 실제 세션에서 관찰하지 못했습니다.

세션으로 인정하는 조건:

- 파일명이 `<pid>.json` 형태(그 밖의 파일은 무시), 크기 256KiB 이하, JSON 파싱 성공(쓰는 도중의 부분 파일은 건너뜀)
- `kill(pid, 0)`으로 프로세스가 살아 있음
- 파일의 `procStart`가 있으면 커널이 기록한 실제 시작 시각과 일치(PID 재사용 방지). 파일 값이 UTC인지 로컬 시간인지 단정하지 못해 두 해석 중 하나라도 맞으면 일치로 봅니다.

세션명은 `name` -> `cwd`의 마지막 경로 요소 -> `이름 없음` 순으로 정합니다.

### 서브에이전트

- 살아 있는 세션의 `sessionId`마다 `~/.claude/projects/*/<sessionId>/subagents/agent-<id>.meta.json`을 찾습니다.
- 다음을 모두 만족하면 실행 중으로 보고 활성 개수에 1개씩 더합니다.
  - `meta.json`의 `finished`가 `true`가 아님
  - `meta.json`과 짝인 `agent-<id>.jsonl` 중 더 늦은 수정 시각이 최근 10분(600초) 이내 (비정상 종료로 `finished`가 안 붙은 잔존물 제외)
- `jsonl`은 수정 시각만 보고 내용은 읽지 않습니다. `meta.json`은 `description`과 `finished`만 사용합니다.
- 표시명은 `↳ <description>`(비어 있으면 `↳ 서브에이전트`)이며, 클릭 시에는 부모 세션의 앱을 앞으로 가져옵니다.

### 감시 방식

`~/.claude/sessions`와 `~/.claude/projects`를 FSEvents로 감시하고, 이벤트는 2초 디바운스 후 한 번 스캔합니다. 이벤트가 없어도 15초마다 다시 스캔합니다(프로세스 종료는 파일 변경 없이 일어날 수 있기 때문). 결과가 이전과 같으면 내보내지 않습니다.

### 세션 앱 전면화

`SessionActivator`가 세션 pid에서 부모 프로세스를 거슬러 올라가 처음 만나는 일반 앱(`activationPolicy == .regular`)을 활성화합니다. `entrypoint`가 `claude-desktop`이면 Claude 데스크탑 앱이어야 하며 아니면 실행 중인 Claude 앱으로 폴백합니다. 앱 안의 탭/창 선택은 하지 않으며, 앱을 찾지 못하면(예: tmux로 사슬이 끊김) 경고음만 냅니다.

## 사용량 API 관찰 사항

Claude Code에서 확인한 **비공식** 엔드포인트이며 언제든 바뀔 수 있습니다.

- `GET https://api.anthropic.com/api/oauth/usage`
- 헤더: `Authorization: Bearer <access token>`, `anthropic-beta: oauth-2025-04-20`, `Accept: application/json`
- 응답 필드 중 사용하는 것:

| 필드 | 사용 방식 |
|---|---|
| `five_hour` | `utilization`(퍼센트), `resets_at`. `resets_at`이 `null`이면 "활성 5시간 창 없음"이지 한도 없음이 아니므로 창은 유지하고 시간만 비움. `five_hour`가 없거나 `null`이면 `limits`의 `kind == "session"`으로 폴백 |
| `seven_day` | 주간 한도. 없으면 `limits`의 `kind == "weekly_all"`로 폴백 |
| `seven_day_*fable*` 키 / `limits` | Fable 한도. 키 이름이나 `limits` 항목의 `kind`/`scope`에 `fable`이 들어 있을 때만. 없으면 표시하지 않음 |
| `limits` | 위 폴백 용도의 배열 |
| `spend` | `used`(`amount_minor`, `exponent`, `currency`)로 사용액 계산. 총량은 `limit` -> `cap` -> `balance` 중 처음으로 금액 객체인 값. `enabled`로 활성 여부 |
| `extra_usage` | `is_enabled == true`일 때 `monthly_limit`/`used_credits`/`currency`. `spend`가 없을 때의 크레딧 폴백이자 `spend.enabled`가 없을 때의 활성 여부 폴백 |

- 퍼센트 키는 `utilization` -> `used_percentage` -> `used_percent` -> `percent` 순으로 시도합니다. 시각은 ISO 8601(소수초 자릿수 무관) 또는 epoch 초/밀리초를 받습니다.
- 모든 필드는 선택적으로 취급합니다. 사용하지 않은 **null이 아닌** 키는 키 이름만 로그(`unmapped usage keys`)에 남깁니다.
- 세션 초기화 티켓은 실제 응답에서 해당 필드를 찾지 못해, 이름에 `ticket`이 들어간 키를 찾는 추정 매핑만 남아 있습니다(UI는 값이 있을 때만 줄을 표시). 지원한다고 보면 안 됩니다.
- 활성화된 `spend`/Fable의 실제 형태는 본 적이 없습니다(비활성 응답만 확인). 해당 부분은 추정입니다.
- **쿼리 변형**: `at_wall=1`, `cedar_ember=1`, `starry_waterfall=cli_menu`, `skip_spend=1` 등은 Claude Code 바이너리에서 문자열로 본 것일 뿐 의미를 확인하지 못했습니다. 앱은 변형 없이 호출하며, 변형은 `--probe-usage` 진단(`UsageProbe`)에서만 순차 호출해 응답을 파일로 저장합니다. 429나 토큰 오류가 나면 중단합니다.
- 오류 처리: 401 -> 인증 실패, 429 -> `Retry-After`(초 또는 HTTP-date) 반영, 그 외 HTTP/네트워크 오류. `UsagePoller`는 실패 시 지수 백오프(최대 10분)를 적용하고, 이전 성공값은 유지한 채 메뉴에 갱신 실패를 표시합니다. 백오프 중에는 메뉴를 열어도 즉시 갱신하지 않습니다.
- 마지막 응답 원문은 디버깅용으로 `~/Library/Application Support/ClawdCounter/last_usage_raw.json`(0600)에 덮어씁니다. 토큰/헤더는 저장하지 않습니다.

## 인증

- **방식**: 앱 자체 OAuth 로그인(Authorization Code + PKCE S256). Claude Code의 자격증명은 읽거나 쓰지 않습니다.
- **설정**(`OAuthConfig.claudeAI`): 클라이언트 ID와 엔드포인트는 Claude Code에서 확인한 비공식 값입니다. 인증 페이지는 `claude.com`, 토큰 발급/갱신/폐기는 `platform.claude.com`을 씁니다. 요청 scope는 `user:profile user:inference`입니다.
- **콜백 서버**: `127.0.0.1`의 임의 포트에 일회용 HTTP 서버(`Network.framework`)를 열고 `http://localhost:<port>/callback`을 리다이렉트로 사용합니다. `state`가 일치할 때만 코드를 받고, 대기 시간은 180초입니다. 코드 교환이 끝나면 브라우저를 성공 페이지로 보냅니다. 서버는 IPv4(127.0.0.1)에만 바인딩하므로, 브라우저가 `localhost`를 IPv6(`::1`)로 먼저 시도하는 환경에서는 실패할 수 있습니다(코드에 TODO로 남아 있음).
- **수동 코드 폴백**: 콜백 서버를 열 수 없을 때(`callbackServerUnavailable`)에만 자동 전환됩니다. 브라우저에 표시된 `code#state` 문자열을 입력창에 붙여넣으면 `state`를 확인하고 코드를 교환합니다.
- **저장**: `StoredTokens`(액세스/리프레시 토큰, 만료 시각, scope)를 JSON으로 키체인에 저장합니다(service `ClawdCounter-credentials`, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`). `StoredTokens`의 문자열 표현은 항상 마스킹됩니다.
- **갱신(refresh) 직렬화**: `AuthManager`는 actor이고, 만료 60초 전부터 갱신합니다. 동시에 여러 호출이 와도 진행 중인 갱신 Task 하나를 공유해 요청을 한 번만 보냅니다. `logout`/새 로그인마다 증가하는 세대 번호로, 그 이전에 시작된 갱신/로그인 결과가 뒤늦게 반영되는 것을 막습니다.
- **만료**: 갱신이 `invalid_grant`(HTTP 400/401)이면 토큰을 지우고 `expired` 상태로 전환합니다. 로그인 진행 중에 발생하면 상태/저장소를 건드리지 않고 로그인이 끝날 때 정리합니다.
- **로그아웃**: 진행 중인 갱신/로그인을 취소하고 로컬 토큰을 삭제한 뒤 서버에 폐기를 시도합니다(실패 무시).

## 동시성 주의

- `Broadcaster<T>`는 구독자마다 `AsyncStream`을 만들며 버퍼를 **최신 1개**(`bufferingNewest(1)`)만 유지합니다. 상태 스트림 용도라서 느린 소비자는 중간 값을 건너뛰고 최신 값만 받습니다. `replayLatest`가 켜져 있으면 새 구독자에게 마지막 값을 즉시 전달합니다(세션 개수, 인증 상태에 사용).
- `SessionMonitor`의 가변 상태는 모두 전용 직렬 큐에서만 접근합니다. `FSEventsWatcher`의 콜백은 감시자 대신 `CallbackBox`만 참조해, 감시자가 먼저 해제돼도 use-after-free가 나지 않게 합니다.
- UI 관련 타입(`AppModel`, `UsagePoller`, `MenuBuilder`)은 `@MainActor`입니다. `UsagePoller`는 세대 번호로 `stop()` 이후 늦게 도착한 결과를 버립니다.
- 테스트에서 `Process.waitUntilExit()`를 쓰지 않습니다. async 테스트(협력 스레드)에서 종료 알림을 받지 못해 무한 대기한 적이 있어, 상한 있는 폴링으로 대신합니다.

## 테스트 전략과 한계

`swift test`로 모듈별 테스트 타깃을 실행합니다(`CoreModelsTests`, `SessionsKitTests`, `AuthKitTests`, `UsageKitTests`, `MenuBarUITests`).

- **CoreModels**: `Broadcaster`(최신값 버퍼링, 재생, 구독 해제, 동시 전송), `SessionCounts`.
- **SessionsKit**: 임시 디렉터리의 세션 파일 픽스처 + 실제 짧은 프로세스로 생존/종료 판정, 상태 매핑, 서브에이전트 판정, 부모 사슬 탐색(가짜 프로세스 트리 주입).
- **AuthKit**: PKCE, 콜백 서버(state 불일치, 타임아웃, 취소 등), `AuthManager`의 로그인/갱신/만료/로그아웃. HTTP 전송과 저장소는 가짜로 주입하며 실제 네트워크는 쓰지 않습니다. 키체인 테스트는 임의 service 이름으로 격리합니다.
- **UsageKit**: 마스킹한 실제 응답(`Tests/UsageKitTests/Fixtures/usage_real.json`)과 합성 픽스처로 매핑을 검증하고, 가짜 전송으로 `UsageClient`/`UsageProbe`의 상태 코드, `Retry-After`, 파일 출력을 검증합니다.
- **MenuBarUI**: 메뉴 구조(텍스트 덤프 기반), 시간 포맷, 사용률 단계, 렌더러의 요소 구성을 검증합니다.

한계:

- 실제 로그인/키체인 확인창/Gatekeeper 흐름과 실제 메뉴바에서의 그리기는 자동 테스트로 확인하지 않습니다. UI는 `swift run RenderPreview`가 만드는 PNG를 눈으로 확인합니다.
- 실제 응답 픽스처는 Max 5x 계정 하나뿐입니다. 다른 요금제의 응답 형태는 검증되지 않았습니다.
- 응답대기(`waiting`) 상태와 활성화된 Fable/크레딧 응답은 합성 데이터로만 검증했습니다.
- 세션 앱 전면화는 macOS 앱 활성화 정책에 의존하므로 환경별 차이가 있을 수 있습니다.
