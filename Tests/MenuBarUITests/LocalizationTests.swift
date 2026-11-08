import AppKit
import CoreModels
import XCTest
@testable import MenuBarUI

/// 언어별 메뉴·상태바 문자열. 전역 언어는 바꾸지 않고 `lang:` 을 명시한다(테스트 병렬 실행 대비).
@MainActor
final class LocalizationTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    var usage: UsageSnapshot {
        UsageSnapshot(
            fiveHour: LimitWindow(usedPercent: 42, resetsAt: now.addingTimeInterval(3 * 3600 + 20 * 60)),
            weekly: LimitWindow(usedPercent: 63, resetsAt: now.addingTimeInterval(3 * 86400 + 5 * 3600)),
            fetchedAt: now)
    }

    func titles(_ lang: Language, auth: AuthState = .signedIn, sessions: SessionCounts? = nil) -> [String] {
        let s = sessions ?? SessionCounts(active: 1, waiting: 0, idle: 0, activeNames: ["a"])
        let menu = MenuBuilder(actions: nil).buildMenu(usage: usage, sessions: s, auth: auth, now: now, lang: lang)
        return menu.items.map { $0.isSeparatorItem ? "---" : $0.title }
    }

    func testMenuTitlesPerLanguage() {
        XCTAssertEqual(titles(.en), [
            "5-hour limit 42% (3h 20m)", "Weekly limit 63% (3d 5h)", "---",
            "● Active 1", "    · a", "● Waiting 0", "○ Idle 0", "---",
            "Log out of Claude", "Settings…", "---", "Quit",
        ])
        XCTAssertEqual(titles(.zhHans), [
            "5 小时限额 42% (3 小时 20 分)", "每周限额 63% (3 天 5 小时)", "---",
            "● 活跃 1", "    · a", "● 等待响应 0", "○ 空闲 0", "---",
            "退出 Claude 登录", "设置…", "---", "退出",
        ])
        XCTAssertEqual(titles(.ja), [
            "5時間上限 42% (3時間20分)", "週間上限 63% (3日5時間)", "---",
            "● アクティブ 1", "    · a", "● 応答待ち 0", "○ 非アクティブ 0", "---",
            "Claude からログアウト", "設定…", "---", "終了",
        ])
        XCTAssertEqual(titles(.en, auth: .signedOut).suffix(4), ["Log in to Claude", "Settings…", "---", "Quit"])
    }

    func testStatusBarTextPerLanguage() {
        typealias R = StatusItemRenderer
        func text(_ auth: AuthState, _ lang: Language) -> [R.Element] { R.leadingElements(usage: nil, auth: auth, now: now, lang: lang) }
        XCTAssertEqual(text(.signedOut, .en), [.text("Login required", .label)])
        XCTAssertEqual(text(.expired, .en), [.text("Log in again", .label)])
        XCTAssertEqual(text(.signedOut, .zhHans), [.text("需要登录", .label)])
        XCTAssertEqual(text(.expired, .ja), [.text("再ログインが必要", .label)])
        // 남은 시간 축약형은 언어와 무관하다.
        XCTAssertEqual(R.leadingElements(usage: usage, auth: .signedIn, now: now, lang: .ja).first, .text("3h 20m", .label))
    }

    func testOverflowAndPlaceholderNames() {
        let s = SessionCounts(
            active: 10, waiting: 0, idle: 0,
            activeSessions: (1...8).map { SessionRef(name: "s\($0)") } + [
                SessionRef(name: "", placeholder: .unnamed), SessionRef(name: "", isSubagent: true, placeholder: .subagent),
            ],
            waitingSessions: [], idleSessions: [])
        XCTAssertTrue(titles(.en, sessions: s).contains("    +2 more"))
        XCTAssertTrue(titles(.ko, sessions: s).contains("    외 2개"))
        func name(_ p: SessionNamePlaceholder, _ lang: Language) -> String {
            MenuBuilder.sessionName(SessionRef(name: "", placeholder: p), lang: lang)
        }
        XCTAssertEqual(Language.allCases.map { name(.unnamed, $0) }, ["이름 없음", "Untitled", "未命名", "名前なし"])
        XCTAssertEqual(name(.subagent, .ko), "↳ 서브에이전트")
        XCTAssertEqual(name(.subagent, .en), "↳ Subagent")
        XCTAssertEqual(MenuBuilder.sessionName(SessionRef(name: "내 세션"), lang: .en), "내 세션")
    }

    func testCreditAndTimePerLanguage() {
        let c = CreditUsage(used: 12.5, total: 100, unit: "USD", isEnabled: false)
        XCTAssertEqual(MenuBuilder.creditText(c, lang: .en), "Credits $12.50 / $100.00 (unavailable)")
        XCTAssertEqual(MenuBuilder.creditText(c, lang: .zhHans), "额度 $12.50 / $100.00 (不可用)")
        XCTAssertEqual(MenuBuilder.creditText(c, lang: .ja), "クレジット $12.50 / $100.00 (利用不可)")
        XCTAssertEqual(TimeFormat.remainingLong(seconds: 0, lang: .en), "resets soon")
        XCTAssertEqual(TimeFormat.remainingLong(seconds: 45, lang: .ja), "1分未満")
        XCTAssertEqual(TimeFormat.remainingPhrase(until: now.addingTimeInterval(3600), now: now, lang: .en), "1h left")
    }
}
