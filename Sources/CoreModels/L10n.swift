import Foundation
import os

/// 앱이 지원하는 표시 언어. rawValue 는 UserDefaults 저장값·언어 코드로 쓴다.
public enum Language: String, CaseIterable, Sendable {
    case ko
    case en
    case zhHans = "zh-Hans"
    case ja

    /// 언어 이름은 어느 언어에서든 자기 문자로 표기한다.
    public var nativeName: String {
        switch self {
        case .ko: "한국어"
        case .en: "English"
        case .zhHans: "简体中文"
        case .ja: "日本語"
        }
    }

    /// 현재 표시 언어. 메인 스레드 밖(오류 설명 등)에서도 읽히므로 락으로 보호한다.
    public static var current: Language { currentLanguageLock.withLock { $0 } }

    public static func setCurrent(_ language: Language) {
        currentLanguageLock.withLock { $0 = language }
    }

    /// 시스템 선호 언어 목록(`Locale.preferredLanguages`)을 앞에서부터 보고 처음 일치하는 언어를 고른다. 없으면 영어.
    /// 중국어는 간체(Hans, 또는 스크립트 없이 CN/SG)만 일치로 보고, 번체(Hant, TW/HK/MO)는 건너뛴다.
    public static func resolve(_ preferred: [String]) -> Language {
        for id in preferred {
            let parts = id.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init)
            switch parts.first {
            case "ko": return .ko
            case "en": return .en
            case "ja": return .ja
            case "zh":
                let rest = Set(parts.dropFirst())
                if rest.contains("hans") { return .zhHans }
                if rest.contains("hant") || !rest.isDisjoint(with: ["tw", "hk", "mo"]) { continue }
                return .zhHans
            default: continue
            }
        }
        return .en
    }
}

private let currentLanguageLock = OSAllocatedUnfairLock(initialState: Language.resolve(Locale.preferredLanguages))

/// 사용자 언어 설정. 기본값은 시스템 설정을 따른다.
public enum LanguagePreference: Hashable, Sendable {
    case system
    case language(Language)

    public static let defaultsKey = "language"
    /// 설정 창 팝업 순서: 시스템 설정 / 한국어 / English / 简体中文 / 日本語.
    public static let allCases: [LanguagePreference] = [.system] + Language.allCases.map { .language($0) }

    public var rawValue: String {
        switch self {
        case .system: "system"
        case .language(let l): l.rawValue
        }
    }

    public init?(rawValue: String) {
        if rawValue == "system" { self = .system; return }
        guard let l = Language(rawValue: rawValue) else { return nil }
        self = .language(l)
    }

    /// 실제로 쓸 언어.
    public func resolved(preferred: [String] = Locale.preferredLanguages) -> Language {
        switch self {
        case .system: Language.resolve(preferred)
        case .language(let l): l
        }
    }

    /// 팝업 항목 이름. 언어 이름은 자기 문자로, "시스템 설정"만 `lang` 으로 번역한다.
    public func displayName(lang: Language = .current) -> String {
        switch self {
        case .system: L10n.tr(.languageSystem, lang: lang)
        case .language(let l): l.nativeName
        }
    }

    public static func load(from defaults: UserDefaults) -> LanguagePreference {
        defaults.string(forKey: defaultsKey).flatMap(LanguagePreference.init(rawValue:)) ?? .system
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}

/// 코드 기반 문자열 테이블. 앱은 바이너리만 번들에 복사하므로 .lproj 리소스 대신 여기 둔다.
/// 키마다 `T(ko:en:zhHans:ja:)` 4개 인자가 모두 필수라, 번역이 하나라도 빠지면 컴파일 오류가 난다.
/// 인자가 들어가는 문자열은 연관값을 가진 키로 표현한다.
public enum L10n {
    public enum Key: Sendable {
        // 메뉴바(상태 항목)
        case statusLoginRequired
        case statusLoginAgain
        case loggingIn

        // 드롭다운: 한도
        case menuLoginRequired
        case menuLoginExpired
        case loadingUsage
        case limitFiveHour
        case limitWeekly
        case limitFable
        case noActiveWindow
        /// 접근성 문장 앞부분: "<라벨> 42퍼센트".
        case limitSpoken(label: String, percent: Int)

        // 드롭다운: 크레딧·티켓
        case creditWithTotal(used: String, total: String)
        case creditUnavailableSuffix
        case creditUsed(String)
        case creditExtraOff(String)
        case resetTickets(Int)

        // 드롭다운: 세션
        case sessionActive
        case sessionWaiting
        case sessionIdle
        /// 상태 헤더 접근성: "활성 세션 2개".
        case sessionCountSpoken(state: String, count: Int)
        case openSession(String)
        /// 초과 줄: "외 N개".
        case moreCount(Int)
        case moreSessionsSpoken(state: String, count: Int)
        case unnamedSession
        case unnamedSubagent

        // 드롭다운: 설정 구획
        case login
        case loginAgain
        case logout
        case settingsEllipsis
        case quit

        // 남은 시간(드롭다운)
        case days(Int)
        case daysHours(Int, Int)
        case hours(Int)
        case hoursMinutes(Int, Int)
        case minutes(Int)
        case underOneMinute
        case resetsSoon
        /// 접근성 꼬리: "남은 2시간 13분".
        case remaining(String)

        // 앱: 갱신 실패
        case usageRefreshFailed
        case lastRefreshFailed

        // 설정 창
        case settingsTitle
        case launchAtLogin
        case refreshInterval
        case refreshMinutesOption(Int)
        case launchAtLoginFailed
        case loginItemApprovalRequired
        case language
        case languageSystem

        // 수동 코드 입력창
        case manualCodeTitle
        case manualCodeMessage
        case manualCodeLoginButton
        case cancel
        case manualCodePlaceholder
        case loginFailed
        case ok

        // AuthError
        case authNotSignedIn
        case authSessionExpired
        case authLoginInProgress
        case authCancelled
        case authTimeout
        case authStateMismatch
        case authInvalidManualCode
        case authDenied(String)
        case authCallbackServerUnavailable
        case authTokenExchangeFailed(status: Int)
        case authRefreshFailed(status: Int)
        case authInvalidResponse
        case networkError(code: Int)
        case keychainError(status: Int32)

        // UsageError
        case usageTokenUnavailable
        case usageUnauthorized
        case usageRateLimited(retryAfterSeconds: Int?)
        case usageHTTP(status: Int)
        case usageInvalidResponse
    }

    public static func tr(_ key: Key, lang: Language = .current) -> String {
        table(key).pick(lang)
    }

    /// 한 키의 4개 언어 번역.
    struct T {
        let ko: String, en: String, zhHans: String, ja: String
        init(ko: String, en: String, zhHans: String, ja: String) {
            self.ko = ko; self.en = en; self.zhHans = zhHans; self.ja = ja
        }
        func pick(_ lang: Language) -> String {
            switch lang {
            case .ko: ko
            case .en: en
            case .zhHans: zhHans
            case .ja: ja
            }
        }
    }

    static func table(_ key: Key) -> T {
        switch key {
        // 메뉴바
        case .statusLoginRequired:
            T(ko: "로그인 필요", en: "Login required", zhHans: "需要登录", ja: "ログインが必要")
        case .statusLoginAgain:
            T(ko: "다시 로그인 필요", en: "Log in again", zhHans: "需要重新登录", ja: "再ログインが必要")
        case .loggingIn:
            T(ko: "로그인 중…", en: "Logging in…", zhHans: "正在登录…", ja: "ログイン中…")

        // 한도
        case .menuLoginRequired:
            T(ko: "Claude 로그인이 필요합니다", en: "Log in to Claude to see usage",
              zhHans: "需要登录 Claude", ja: "Claude へのログインが必要です")
        case .menuLoginExpired:
            T(ko: "로그인이 만료되었습니다", en: "Your login has expired", zhHans: "登录已过期", ja: "ログインの有効期限が切れました")
        case .loadingUsage:
            T(ko: "사용량 불러오는 중…", en: "Loading usage…", zhHans: "正在加载用量…", ja: "使用量を読み込み中…")
        case .limitFiveHour:
            T(ko: "5시간 한도", en: "5-hour limit", zhHans: "5 小时限额", ja: "5時間上限")
        case .limitWeekly:
            T(ko: "주간 한도", en: "Weekly limit", zhHans: "每周限额", ja: "週間上限")
        case .limitFable:
            T(ko: "Fable 한도", en: "Fable limit", zhHans: "Fable 限额", ja: "Fable 上限")
        case .noActiveWindow:
            T(ko: "활성 창 없음", en: "no active window", zhHans: "无活跃窗口", ja: "アクティブな枠なし")
        case .limitSpoken(let label, let p):
            T(ko: "\(label) \(p)퍼센트", en: "\(label) \(p) percent", zhHans: "\(label) 百分之 \(p)", ja: "\(label) \(p)パーセント")

        // 크레딧·티켓
        case .creditWithTotal(let used, let total):
            T(ko: "크레딧 \(used) / \(total)", en: "Credits \(used) / \(total)",
              zhHans: "额度 \(used) / \(total)", ja: "クレジット \(used) / \(total)")
        case .creditUnavailableSuffix:
            T(ko: " (사용 불가)", en: " (unavailable)", zhHans: " (不可用)", ja: " (利用不可)")
        case .creditUsed(let used):
            T(ko: "크레딧 \(used) 사용", en: "Credits \(used) used", zhHans: "额度已用 \(used)", ja: "クレジット \(used) 使用")
        case .creditExtraOff(let used):
            T(ko: "크레딧 \(used) (추가 사용 꺼짐)", en: "Credits \(used) (extra usage off)",
              zhHans: "额度 \(used) (额外用量已关闭)", ja: "クレジット \(used) (追加使用オフ)")
        case .resetTickets(let n):
            T(ko: "세션 초기화 티켓 \(n)장", en: "Session reset tickets: \(n)",
              zhHans: "会话重置券 \(n) 张", ja: "セッションリセットチケット \(n) 枚")

        // 세션
        case .sessionActive:
            T(ko: "활성", en: "Active", zhHans: "活跃", ja: "アクティブ")
        case .sessionWaiting:
            T(ko: "응답대기", en: "Waiting", zhHans: "等待响应", ja: "応答待ち")
        case .sessionIdle:
            T(ko: "비활성", en: "Idle", zhHans: "空闲", ja: "非アクティブ")
        case .sessionCountSpoken(let state, let n):
            T(ko: "\(state) 세션 \(n)개", en: "\(state) sessions: \(n)",
              zhHans: "\(state)会话 \(n) 个", ja: "\(state)のセッション \(n) 件")
        case .openSession(let name):
            T(ko: "세션 \(name) 열기", en: "Open session \(name)", zhHans: "打开会话 \(name)", ja: "セッション \(name) を開く")
        case .moreCount(let n):
            T(ko: "외 \(n)개", en: "+\(n) more", zhHans: "另外 \(n) 个", ja: "他 \(n) 件")
        case .moreSessionsSpoken(let state, let n):
            T(ko: "그 밖에 \(state) 세션 \(n)개", en: "\(state) sessions: +\(n) more",
              zhHans: "另外 \(n) 个\(state)会话", ja: "他に\(state)のセッション \(n) 件")
        case .unnamedSession:
            T(ko: "이름 없음", en: "Untitled", zhHans: "未命名", ja: "名前なし")
        case .unnamedSubagent:
            T(ko: "↳ 서브에이전트", en: "↳ Subagent", zhHans: "↳ 子代理", ja: "↳ サブエージェント")

        // 설정 구획
        case .login:
            T(ko: "Claude 로그인", en: "Log in to Claude", zhHans: "登录 Claude", ja: "Claude にログイン")
        case .loginAgain:
            T(ko: "Claude 다시 로그인", en: "Log in to Claude again", zhHans: "重新登录 Claude", ja: "Claude に再ログイン")
        case .logout:
            T(ko: "Claude 로그아웃", en: "Log out of Claude", zhHans: "退出 Claude 登录", ja: "Claude からログアウト")
        case .settingsEllipsis:
            T(ko: "설정…", en: "Settings…", zhHans: "设置…", ja: "設定…")
        case .quit:
            T(ko: "종료", en: "Quit", zhHans: "退出", ja: "終了")

        // 남은 시간
        case .days(let d):
            T(ko: "\(d)일", en: "\(d)d", zhHans: "\(d) 天", ja: "\(d)日")
        case .daysHours(let d, let h):
            T(ko: "\(d)일 \(h)시간", en: "\(d)d \(h)h", zhHans: "\(d) 天 \(h) 小时", ja: "\(d)日\(h)時間")
        case .hours(let h):
            T(ko: "\(h)시간", en: "\(h)h", zhHans: "\(h) 小时", ja: "\(h)時間")
        case .hoursMinutes(let h, let m):
            T(ko: "\(h)시간 \(m)분", en: "\(h)h \(m)m", zhHans: "\(h) 小时 \(m) 分", ja: "\(h)時間\(m)分")
        case .minutes(let m):
            T(ko: "\(m)분", en: "\(m)m", zhHans: "\(m) 分", ja: "\(m)分")
        case .underOneMinute:
            T(ko: "1분 미만", en: "<1m", zhHans: "不到 1 分", ja: "1分未満")
        case .resetsSoon:
            T(ko: "곧 초기화", en: "resets soon", zhHans: "即将重置", ja: "まもなくリセット")
        case .remaining(let t):
            T(ko: "남은 \(t)", en: "\(t) left", zhHans: "剩余 \(t)", ja: "残り \(t)")

        // 갱신 실패
        case .usageRefreshFailed:
            T(ko: "사용량 갱신 실패", en: "Usage refresh failed", zhHans: "用量刷新失败", ja: "使用量の更新に失敗")
        case .lastRefreshFailed:
            T(ko: "마지막 갱신 실패 · 이전 값 표시", en: "Last refresh failed · showing previous values",
              zhHans: "上次刷新失败 · 显示之前的值", ja: "前回の更新に失敗 · 以前の値を表示")

        // 설정 창
        case .settingsTitle:
            T(ko: "ClawdCounter 설정", en: "ClawdCounter Settings", zhHans: "ClawdCounter 设置", ja: "ClawdCounter 設定")
        case .launchAtLogin:
            T(ko: "로그인 시 자동 실행", en: "Launch at login", zhHans: "登录时自动启动", ja: "ログイン時に自動起動")
        case .refreshInterval:
            T(ko: "사용량 갱신 주기", en: "Usage refresh interval", zhHans: "用量刷新间隔", ja: "使用量の更新間隔")
        case .refreshMinutesOption(let m):
            T(ko: "\(m)분", en: "\(m) min", zhHans: "\(m) 分钟", ja: "\(m)分")
        case .launchAtLoginFailed:
            T(ko: "자동 실행 설정에 실패했습니다", en: "Couldn't change launch at login",
              zhHans: "无法更改登录时自动启动", ja: "ログイン時の自動起動を設定できませんでした")
        case .loginItemApprovalRequired:
            T(ko: "시스템 설정의 로그인 항목에서 승인이 필요합니다", en: "Approve it in System Settings > Login Items",
              zhHans: "需要在系统设置的登录项中批准", ja: "システム設定のログイン項目で承認が必要です")
        case .language:
            T(ko: "언어", en: "Language", zhHans: "语言", ja: "言語")
        case .languageSystem:
            T(ko: "시스템 설정", en: "System default", zhHans: "跟随系统", ja: "システム設定に従う")

        // 수동 코드 입력창
        case .manualCodeTitle:
            T(ko: "Claude 로그인 코드 입력", en: "Enter Claude login code", zhHans: "输入 Claude 登录代码", ja: "Claude ログインコードを入力")
        case .manualCodeMessage:
            T(ko: "브라우저에서 로그인한 뒤 표시되는 코드를 아래에 붙여넣으세요.",
              en: "After logging in in your browser, paste the code it shows below.",
              zhHans: "在浏览器中登录后，将显示的代码粘贴到下方。",
              ja: "ブラウザでログインした後、表示されたコードを下に貼り付けてください。")
        case .manualCodeLoginButton:
            T(ko: "로그인", en: "Log In", zhHans: "登录", ja: "ログイン")
        case .cancel:
            T(ko: "취소", en: "Cancel", zhHans: "取消", ja: "キャンセル")
        case .manualCodePlaceholder:
            T(ko: "코드#상태", en: "code#state", zhHans: "代码#状态", ja: "コード#状態")
        case .loginFailed:
            T(ko: "로그인에 실패했습니다", en: "Login failed", zhHans: "登录失败", ja: "ログインに失敗しました")
        case .ok:
            T(ko: "확인", en: "OK", zhHans: "确定", ja: "OK")

        // AuthError
        case .authNotSignedIn:
            T(ko: "로그인되어 있지 않습니다.", en: "Not logged in.", zhHans: "尚未登录。", ja: "ログインしていません。")
        case .authSessionExpired:
            T(ko: "로그인이 만료되었습니다. 다시 로그인하세요.", en: "Your login has expired. Please log in again.",
              zhHans: "登录已过期，请重新登录。", ja: "ログインの有効期限が切れました。再ログインしてください。")
        case .authLoginInProgress:
            T(ko: "이미 로그인이 진행 중입니다.", en: "A login is already in progress.",
              zhHans: "登录已在进行中。", ja: "すでにログイン処理中です。")
        case .authCancelled:
            T(ko: "로그인이 취소되었습니다.", en: "Login was cancelled.", zhHans: "登录已取消。", ja: "ログインがキャンセルされました。")
        case .authTimeout:
            T(ko: "로그인 대기 시간이 초과되었습니다.", en: "Login timed out.", zhHans: "登录等待超时。", ja: "ログインの待機時間を超えました。")
        case .authStateMismatch:
            T(ko: "로그인 응답 검증(state)에 실패했습니다.", en: "Login response verification (state) failed.",
              zhHans: "登录响应验证 (state) 失败。", ja: "ログイン応答の検証 (state) に失敗しました。")
        case .authInvalidManualCode:
            T(ko: "코드 형식이 올바르지 않습니다. 전체 코드를 복사했는지 확인하세요.",
              en: "The code format is invalid. Make sure you copied the whole code.",
              zhHans: "代码格式不正确。请确认已复制完整代码。",
              ja: "コードの形式が正しくありません。コード全体をコピーしたか確認してください。")
        case .authDenied(let code):
            T(ko: "로그인이 거부되었습니다 (\(code)).", en: "Login was denied (\(code)).",
              zhHans: "登录被拒绝 (\(code))。", ja: "ログインが拒否されました (\(code))。")
        case .authCallbackServerUnavailable:
            T(ko: "로컬 콜백 서버를 시작할 수 없습니다.", en: "Couldn't start the local callback server.",
              zhHans: "无法启动本地回调服务器。", ja: "ローカルのコールバックサーバーを起動できません。")
        case .authTokenExchangeFailed(let s):
            T(ko: "토큰 교환 실패 (HTTP \(s)).", en: "Token exchange failed (HTTP \(s)).",
              zhHans: "令牌交换失败 (HTTP \(s))。", ja: "トークンの交換に失敗しました (HTTP \(s))。")
        case .authRefreshFailed(let s):
            T(ko: "토큰 갱신 실패 (HTTP \(s)).", en: "Token refresh failed (HTTP \(s)).",
              zhHans: "令牌刷新失败 (HTTP \(s))。", ja: "トークンの更新に失敗しました (HTTP \(s))。")
        case .authInvalidResponse:
            T(ko: "서버 응답 형식이 올바르지 않습니다.", en: "The server response format is invalid.",
              zhHans: "服务器响应格式不正确。", ja: "サーバー応答の形式が正しくありません。")
        case .networkError(let code):
            T(ko: "네트워크 오류 (\(code)).", en: "Network error (\(code)).", zhHans: "网络错误 (\(code))。", ja: "ネットワークエラー (\(code))。")
        case .keychainError(let s):
            T(ko: "키체인 오류 (\(s)).", en: "Keychain error (\(s)).", zhHans: "钥匙串错误 (\(s))。", ja: "キーチェーンエラー (\(s))。")

        // UsageError
        case .usageTokenUnavailable:
            T(ko: "액세스 토큰을 얻지 못했습니다.", en: "Couldn't get an access token.",
              zhHans: "无法获取访问令牌。", ja: "アクセストークンを取得できませんでした。")
        case .usageUnauthorized:
            T(ko: "사용량 조회 인증 실패 (HTTP 401).", en: "Usage request was not authorized (HTTP 401).",
              zhHans: "用量查询认证失败 (HTTP 401)。", ja: "使用量取得の認証に失敗しました (HTTP 401)。")
        case .usageRateLimited(let s):
            T(ko: "사용량 조회 한도 초과 (HTTP 429)" + (s.map { ", \($0)초 후 재시도" } ?? "") + ".",
              en: "Usage request rate limited (HTTP 429)" + (s.map { ", retrying in \($0)s" } ?? "") + ".",
              zhHans: "用量查询超出频率限制 (HTTP 429)" + (s.map { "，\($0) 秒后重试" } ?? "") + "。",
              ja: "使用量取得の回数制限を超えました (HTTP 429)" + (s.map { "、\($0)秒後に再試行" } ?? "") + "。")
        case .usageHTTP(let s):
            T(ko: "사용량 조회 실패 (HTTP \(s)).", en: "Usage request failed (HTTP \(s)).",
              zhHans: "用量查询失败 (HTTP \(s))。", ja: "使用量の取得に失敗しました (HTTP \(s))。")
        case .usageInvalidResponse:
            T(ko: "사용량 응답 형식이 올바르지 않습니다.", en: "The usage response format is invalid.",
              zhHans: "用量响应格式不正确。", ja: "使用量応答の形式が正しくありません。")
        }
    }
}
