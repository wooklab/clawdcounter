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

## 구조
```
Package.swift                      # targets: ClawdCounterCore(lib), ClawdCounter(exe), ClawdCounterCoreTests
Sources/ClawdCounterCore/Models.swift     # [스캐폴드가 작성·이후 동결] 공유 타입/프로토콜
Sources/ClawdCounterCore/Sessions/        # 에이전트 S
Sources/ClawdCounterCore/Auth/            # 에이전트 A
Sources/ClawdCounterCore/Usage/           # 에이전트 U
Sources/ClawdCounter/UI/                  # 에이전트 I (메뉴바 렌더링, 메뉴, 설정창)
Sources/ClawdCounter/main.swift|AppDelegate.swift  # 통합 단계
scripts/build_app.sh                      # .app 번들 생성 (Info.plist LSUIElement)
```

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
