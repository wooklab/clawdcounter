# ClawdCounter 설계 + 작업분배

macOS 메뉴바 앱. Claude Code 토큰 사용량 + 세션 현황 표시.

## 확정 사항 (사용자 결정)
- 사용량: 앱 **자체 OAuth 로그인**(PKCE)으로 사용량 API 호출. Claude Code 키체인 토큰은 읽지도 건드리지도 않는다. 메뉴에 로그인/로그아웃 버튼. 토큰은 앱 전용 키체인 항목(`ClawdCounter-credentials`)에 저장.
- 세션 상태: `~/.claude/sessions/<pid>.json`의 `status` 감시 (hook 사용 안 함). 상태 3종: 활성(초록 ●) / 응답대기(노랑 ●) / 비활성 idle(빈 ○).
- 5시간 한도가 없는 요금제 → 5시간 표시 숨김, 주간만.
- 메뉴바 표기: `5h남은시간 | [5h바][주간바] | ●활성 ○비활성 ●응답대기` (색 구분)
- 드롭다운(구분선으로 구획): 한도(5h+남은시간, 주간+남은시간, Fable[불가 시 비노출]) / 크레딧 사용량÷총량 / 세션 초기화 티켓 / 세션(활성·응답대기·비활성 수) / 설정 / 종료. 로그인·로그아웃 버튼 포함(위치: 설정 구획 위 또는 안).

## 작성자 판단 (사용자 미확인, 틀리면 알려주세요)
- Swift 6 / SwiftPM, macOS 14+, AppKit `NSStatusItem`(커스텀 렌더링) + 메뉴는 `NSMenu`. LSUIElement(독 아이콘 없음). 샌드박스 없음(홈 디렉터리 읽기 필요), ad-hoc 서명, 로컬 빌드 전용.
- 사용량 폴링 60초(설정: 1/2/5분), 429 시 백오프. 세션은 FSEvents + 2초 디바운스 + 죽은 pid 필터.
- 설정: 로그인 시 자동 실행, 갱신 주기. 그 외 없음.
- UI 문자열 한국어.
- OAuth는 Claude Code의 공개 client_id/엔드포인트를 설치된 `claude` 바이너리·플러그인에서 확인해 재사용(비공식, 깨질 수 있음). 로컬 콜백 서버 방식 우선, 수동 코드 붙여넣기 폴백.

## 미확인 (구현 중 검증)
- 사용량 API 응답에 크레딧/Fable/초기화 티켓 필드가 있는지 → 모든 필드 optional, 없으면 해당 줄 비노출. 실제 응답 확인은 사용자가 로그인한 뒤에만 가능.
- sessions JSON `status`의 응답대기 값 (알려진 값: idle, busy). `claude` 바이너리 문자열/세션 파일/transcript로 조사하고 모르면 `waiting` 후보를 설정 가능한 매핑 테이블로.

## 구조 (개정: 병렬 빌드 충돌 방지를 위해 타깃 분리)
```
Package.swift   # 라이브러리 타깃 CoreModels / SessionsKit / AuthKit / UsageKit (Kit들은 CoreModels에만 의존), 실행 타깃 ClawdCounter(UI 포함, 전부 의존), 각 Kit별 테스트 타깃 SessionsKitTests/AuthKitTests/UsageKitTests
Sources/CoreModels/Models.swift     # [스캐폴드 작성 후 동결] 아래 공유 타입/프로토콜
Sources/SessionsKit/  Sources/AuthKit/  Sources/UsageKit/
Sources/ClawdCounter/ (UI/, main.swift, AppDelegate.swift)
Sources/RenderPreview/  # 디버그 실행 타깃: 상태바 NSImage를 케이스별 PNG로 출력
scripts/build_app.sh    # .app 번들(Info.plist LSUIElement)
```
병렬 에이전트는 각자 `--scratch-path .build-<역할>` 사용 (SwiftPM 락 충돌 방지), `git commit` 금지(메인이 커밋). `.build*`는 .gitignore.
`stateStream()`/`countsStream()`은 AsyncStream(단일 소비자) → Models.swift에 멀티캐스트 헬퍼 `Broadcaster<T>`를 포함하고 구현체는 이를 사용.

## OAuth 사전조사 결과 (claude 2.1.319 바이너리에서 추출, 메인 세션 수행)
- client_id `9d1c250a-e61b-44d9-88ed-5944d1962f5e`
- authorize `https://claude.com/cai/oauth/authorize` (claude.ai 계정), response_type=code, PKCE(S256), `code=true` 쿼리 존재
- token `https://platform.claude.com/v1/oauth/token`
- redirect: 자동 `http://localhost:{port}/callback` (Claude Code가 사용 → 등록됨), 수동 `https://platform.claude.com/oauth/code/callback` (코드 붙여넣기)
- 사용 scope 후보: `user:profile user:inference` (사용량 조회용 최소 조합은 구현 중 확인)
- 사용량 `GET https://api.anthropic.com/api/oauth/usage` (헤더 `Authorization: Bearer`, `anthropic-beta: oauth-2025-04-20`). 쿼리 변형(`at_wall`, `skip_spend`)이 바이너리에 있음 — 의미 불명, 응답 형태 미확인.
- 프로필 `GET https://api.anthropic.com/api/oauth/profile`

## 진행 순서 (개정, 어드바이저 반영)
0 스캐폴드 → {S, A, I} 병렬 → 사용자가 앱에서 로그인(수동) → 메인이 `/api/oauth/usage` 실제 응답을 마스킹해 `Tests/Fixtures/usage_real.json` 저장 → U를 실제 픽스처 기준으로 구현 → 통합 → 리뷰.
(U를 앞당기지 않는 이유: 크레딧/Fable/초기화 티켓 필드의 실제 형태를 모르는 채 디코더를 만들면 아무것도 매핑 안 됨.)
UI(I) 검증: RenderPreview로 케이스(5h 있음/없음, Fable 없음, 세션 0/0/0, 로그아웃) PNG 렌더 후 눈으로 확인.
## 공유 인터페이스 (Models.swift, 동결)
```swift
public struct LimitWindow: Equatable, Sendable { public var usedPercent: Double /*0-100*/; public var resetsAt: Date? }
public struct CreditUsage: Equatable, Sendable { public var used: Double; public var total: Double; public var unit: String? }
public struct ResetTicketStatus: Equatable, Sendable { public var remaining: Int; public var total: Int? }
public struct UsageSnapshot: Equatable, Sendable { public var fiveHour: LimitWindow?; public var weekly: LimitWindow?; public var fable: LimitWindow?; public var credit: CreditUsage?; public var resetTickets: ResetTicketStatus?; public var fetchedAt: Date }
public struct SessionCounts: Equatable, Sendable { public var active: Int; public var waiting: Int; public var idle: Int }
public enum AuthState: Equatable, Sendable { case signedOut, signingIn, signedIn, expired }
public protocol TokenProviding: Sendable { func validAccessToken() async throws -> String }           // 필요 시 refresh
public protocol AuthManaging: TokenProviding { var state: AuthState { get async }; func login() async throws; func logout() async; func stateStream() -> AsyncStream<AuthState> }
public protocol UsageProviding: Sendable { func fetch() async throws -> UsageSnapshot }
public protocol SessionMonitoring: Sendable { func countsStream() -> AsyncStream<SessionCounts> }
```

## 작업 분배 (의존: 0 → {S,A,U,I 병렬} → 통합 → 리뷰)
| # | 역할 | 모델 | 산출/완료 기준 |
|---|------|------|----------------|
| 0 | 스캐폴드 | sonnet | Package.swift, Models.swift, 빈 앱 빌드 성공(`swift build`), build_app.sh |
| S | 세션 모니터 | sonnet | sessions/*.json 파싱·FSEvents·pid 생존 필터·상태 매핑. 픽스처 기반 `swift test` 통과. 응답대기 값 조사 결과 보고 |
| A | 인증 | opus | PKCE 로그인, 키체인 저장, refresh(동시 refresh 직렬화), logout. 토큰/코드 로그 금지. 단위 테스트(PKCE, 토큰 만료, 직렬화). 실제 로그인은 사용자 수행 |
| U | 사용량 | sonnet | 엔드포인트 호출, 관대한 디코딩(전 필드 optional), 5h 없음 처리, 429 백오프, 픽스처 테스트 |
| I | UI | sonnet | NSStatusItem 이미지 렌더(텍스트+2바+3점), NSMenu 구획, 설정창, 모의 데이터 프리뷰로 스크린샷 검증 |
| 통합 | 연결 | sonnet | AppDelegate에서 모니터·Auth·Usage→UI 연결, 상태별 UI(로그아웃/만료/에러) |
| 리뷰 | 검토 | opus | 토큰 취급·동시성·UI 엣지(5h 없음, Fable 없음) 검토 |

파일 소유권 분리로 병렬 에이전트 간 충돌 없음. Models.swift 변경 필요 시 메인 세션에 요청.
