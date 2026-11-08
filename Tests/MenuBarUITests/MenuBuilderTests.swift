import AppKit
import CoreModels
import XCTest
@testable import MenuBarUI

@MainActor
final class MenuBuilderTests: XCTestCase {
    final class Spy: MenuActions {
        var calls: [String] = []
        func login() { calls.append("login") }
        func logout() { calls.append("logout") }
        func quit() { calls.append("quit") }
        func setRefreshInterval(minutes: Int) { calls.append("interval:\(minutes)") }
        func setLaunchAtLogin(_ enabled: Bool) { calls.append("launch:\(enabled)") }
    }

    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let counts = SessionCounts(active: 2, waiting: 1, idle: 4)

    func win(_ pct: Double, _ secs: TimeInterval) -> LimitWindow {
        LimitWindow(usedPercent: pct, resetsAt: now.addingTimeInterval(secs))
    }

    var full: UsageSnapshot {
        UsageSnapshot(
            fiveHour: win(42, 2 * 3600 + 13 * 60),
            weekly: win(63, 3 * 86400 + 5 * 3600),
            fable: win(18, 3 * 86400 + 5 * 3600),
            credit: CreditUsage(used: 12.5, total: 100, unit: "USD"),
            resetTickets: ResetTicketStatus(remaining: 2),
            fetchedAt: now)
    }

    func build(_ usage: UsageSnapshot?, auth: AuthState = .signedIn, settings: MenuSettings = MenuSettings(), spy: Spy = Spy()) -> NSMenu {
        // 빌더를 지역변수로만 쓰고 버려도 클릭이 동작해야 한다.
        MenuBuilder(actions: spy).buildMenu(usage: usage, sessions: counts, auth: auth, settings: settings, now: now)
    }

    func titles(_ menu: NSMenu) -> [String] { menu.items.map { $0.isSeparatorItem ? "---" : $0.title } }

    func testFullStructureAndSectionOrder() {
        XCTAssertEqual(titles(build(full)), [
            "5시간 한도 42% · 남은 2시간 13분",
            "주간 한도 63% · 남은 3일 5시간",
            "Fable 한도 18% · 남은 3일 5시간",
            "---",
            "크레딧 사용량 12.5 / 100 USD",
            "---",
            "세션 초기화 티켓 2장",
            "---",
            "● 활성 2", "● 응답대기 1", "○ 비활성 4",
            "---",
            "로그아웃", "설정",
            "---",
            "종료",
        ])
    }

    func testNoFiveHourHidesThatLine() {
        var u = full; u.fiveHour = nil
        let t = titles(build(u))
        XCTAssertFalse(t.contains { $0.hasPrefix("5시간") })
        XCTAssertEqual(t.first, "주간 한도 63% · 남은 3일 5시간")
    }

    func testFiveHourWithoutActiveWindowShowsNote() {
        let u = UsageSnapshot(
            fiveHour: LimitWindow(usedPercent: 0, resetsAt: nil), weekly: win(5, 6 * 86400), fetchedAt: now)
        XCTAssertEqual(titles(build(u)).prefix(2), ["5시간 한도 0% · 활성 창 없음", "주간 한도 5% · 남은 6일"])
    }

    func testWeeklyWithoutResetHasNoInactiveNote() {
        let u = UsageSnapshot(weekly: LimitWindow(usedPercent: 9), fetchedAt: now)
        XCTAssertEqual(titles(build(u)).first, "주간 한도 9%")
    }

    func testNoFableHidesThatLine() {
        var u = full; u.fable = nil
        XCTAssertFalse(titles(build(u)).contains { $0.hasPrefix("Fable") })
    }

    func testNoCreditHidesSectionWithoutDoubleSeparators() {
        var u = full; u.credit = nil
        let t = titles(build(u))
        XCTAssertFalse(t.contains { $0.hasPrefix("크레딧") })
        XCTAssertEqual(zip(t, t.dropFirst()).filter { $0 == "---" && $1 == "---" }.count, 0)
        XCTAssertEqual(t.filter { $0 == "---" }.count, 4)
    }

    func testNoTicketsHidesSection() {
        var u = full; u.resetTickets = nil
        let t = titles(build(u))
        XCTAssertFalse(t.contains { $0.hasPrefix("세션 초기화") })
        XCTAssertEqual(t.filter { $0 == "---" }.count, 4)
    }

    func testMinimalUsageOnlyWeekly() {
        let u = UsageSnapshot(weekly: win(10, 86400), fetchedAt: now)
        XCTAssertEqual(titles(build(u)).prefix(3), ["주간 한도 10% · 남은 1일", "---", "● 활성 2"])
    }

    func testSignedOutHidesUsageKeepsSessionsAndLogin() {
        let t = titles(build(full, auth: .signedOut))
        XCTAssertEqual(t, ["Claude 로그인이 필요합니다", "---", "● 활성 2", "● 응답대기 1", "○ 비활성 4", "---", "Claude 로그인", "설정", "---", "종료"])
    }

    func testAuthItemTitles() {
        func authTitle(_ a: AuthState) -> String { build(full, auth: a).items.first { $0.title.contains("로그") && $0.action != nil }!.title }
        XCTAssertEqual(authTitle(.signedOut), "Claude 로그인")
        XCTAssertEqual(authTitle(.signedIn), "로그아웃")
        XCTAssertEqual(authTitle(.expired), "다시 로그인")
        let signingIn = build(full, auth: .signingIn).items.first { $0.title == "로그인 중…" && $0.action != nil }
        XCTAssertEqual(signingIn?.isEnabled, false)
    }

    func testLoadingShowsPlaceholder() {
        XCTAssertEqual(titles(build(nil)).first, "사용량 불러오는 중…")
    }

    func testSessionsZeroStillShown() {
        let m = MenuBuilder(actions: nil).buildMenu(usage: nil, sessions: SessionCounts(active: 0, waiting: 0, idle: 0), auth: .signedIn, now: now)
        XCTAssertTrue(titles(m).contains("● 활성 0"))
    }

    func testSettingsChecksAndActions() {
        let spy = Spy()
        let menu = build(full, settings: MenuSettings(launchAtLogin: true, refreshMinutes: 2), spy: spy)
        let settings = menu.items.first { $0.title == "설정" }!.submenu!
        let launch = settings.items[0]
        XCTAssertEqual(launch.state, .on)
        let interval = settings.items[1].submenu!
        XCTAssertEqual(interval.items.map(\.title), ["1분", "2분", "5분"])
        XCTAssertEqual(interval.items.map(\.state), [.off, .on, .off])

        // 클릭 전달
        func fire(_ item: NSMenuItem) { _ = item.target!.perform(item.action!, with: item) }
        fire(launch)
        fire(interval.items[2])
        fire(menu.items.first { $0.title == "로그아웃" }!)
        fire(menu.items.last!)
        XCTAssertEqual(spy.calls, ["launch:false", "interval:5", "logout", "quit"])
    }

    func testCreditNumberFormatting() {
        XCTAssertEqual(MenuBuilder.number(1234.5), "1,234.5")
        XCTAssertEqual(MenuBuilder.number(100), "100")
        XCTAssertEqual(MenuBuilder.number(0.256), "0.26")
    }
}

final class StatusItemRendererTests: XCTestCase {
    func testToneThresholdsInclusive() {
        typealias R = StatusItemRenderer
        XCTAssertEqual(R.tone(forPercent: 79.9), .normal)
        XCTAssertEqual(R.tone(forPercent: 80), .warn)
        XCTAssertEqual(R.tone(forPercent: 94.9), .warn)
        XCTAssertEqual(R.tone(forPercent: 95), .critical)
    }

    func testLeadingElementsRules() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let full = UsageSnapshot(
            fiveHour: LimitWindow(usedPercent: 50, resetsAt: now.addingTimeInterval(2 * 3600 + 13 * 60)),
            weekly: LimitWindow(usedPercent: 120), fetchedAt: now)
        typealias R = StatusItemRenderer
        XCTAssertEqual(R.leadingElements(usage: full, auth: .signedIn, now: now), [
            .text("2h13m", .label), .bar(fraction: 0.5, tone: .normal), .bar(fraction: 1, tone: .critical),
        ])
        var noFive = full; noFive.fiveHour = nil
        XCTAssertEqual(R.leadingElements(usage: noFive, auth: .signedIn, now: now), [.bar(fraction: 1, tone: .critical)])
        XCTAssertEqual(R.leadingElements(usage: nil, auth: .signedIn, now: now), [.text("–", .label)])
        // 활성 5시간 창 없음(resetsAt == nil): 남은시간 자리 "–", 5h 바는 0% 유지
        let inactive = UsageSnapshot(
            fiveHour: LimitWindow(usedPercent: 0, resetsAt: nil), weekly: LimitWindow(usedPercent: 5), fetchedAt: now)
        XCTAssertEqual(R.leadingElements(usage: inactive, auth: .signedIn, now: now), [
            .text("–", .label), .bar(fraction: 0, tone: .normal), .bar(fraction: 0.05, tone: .normal),
        ])
        XCTAssertEqual(R.leadingElements(usage: full, auth: .signedOut, now: now), [.text("로그인 필요", .label)])
        XCTAssertEqual(R.leadingElements(usage: full, auth: .expired, now: now), [.text("다시 로그인 필요", .label)])
    }

    @MainActor
    func testImageIsNonTemplateAndTwentyTwoPointsHigh() {
        let img = StatusItemRenderer.image(
            usage: nil, sessions: SessionCounts(active: 0, waiting: 0, idle: 0), auth: .signedOut,
            appearance: NSAppearance(named: .darkAqua)!)
        XCTAssertFalse(img.isTemplate)
        XCTAssertEqual(img.size.height, 22)
        XCTAssertGreaterThan(img.size.width, 40)
    }
}
