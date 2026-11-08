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
        func openSettings() { calls.append("settings") }
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
            "● 5시간 한도 42% · 남은 2시간 13분",
            "● 주간 한도 63% · 남은 3일 5시간",
            "● Fable 한도 18% · 남은 3일 5시간",
            "---",
            "크레딧 사용량 12.5 / 100 USD",
            "---",
            "세션 초기화 티켓 2장",
            "---",
            "● 활성 2", "● 응답대기 1", "○ 비활성 4",
            "---",
            "로그아웃", "설정…",
            "---",
            "종료",
        ])
    }

    func testNoFiveHourHidesThatLine() {
        var u = full; u.fiveHour = nil
        let t = titles(build(u))
        XCTAssertFalse(t.contains { $0.hasPrefix("● 5시간") })
        XCTAssertEqual(t.first, "● 주간 한도 63% · 남은 3일 5시간")
    }

    func testFiveHourWithoutActiveWindowShowsNote() {
        let u = UsageSnapshot(
            fiveHour: LimitWindow(usedPercent: 0, resetsAt: nil), weekly: win(5, 6 * 86400), fetchedAt: now)
        XCTAssertEqual(titles(build(u)).prefix(2), ["● 5시간 한도 0% · 활성 창 없음", "● 주간 한도 5% · 남은 6일"])
    }

    func testWeeklyWithoutResetHasNoInactiveNote() {
        let u = UsageSnapshot(weekly: LimitWindow(usedPercent: 9), fetchedAt: now)
        XCTAssertEqual(titles(build(u)).first, "● 주간 한도 9%")
    }

    func testNoFableHidesThatLine() {
        var u = full; u.fable = nil
        XCTAssertFalse(titles(build(u)).contains { $0.hasPrefix("● Fable") })
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
        XCTAssertEqual(titles(build(u)).prefix(3), ["● 주간 한도 10% · 남은 1일", "---", "● 활성 2"])
    }

    func testSignedOutHidesUsageKeepsSessionsAndLogin() {
        let t = titles(build(full, auth: .signedOut))
        XCTAssertEqual(t, ["Claude 로그인이 필요합니다", "---", "● 활성 2", "● 응답대기 1", "○ 비활성 4", "---", "Claude 로그인", "설정…", "---", "종료"])
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

    func testSettingsItemHasNoSubmenuAndFiresOpenSettings() {
        let spy = Spy()
        let menu = build(full, spy: spy)
        let item = menu.items.first { $0.title == "설정…" }!
        XCTAssertNil(item.submenu)
        XCTAssertTrue(item.isEnabled)
        XCTAssertFalse(menu.items.contains { $0.title == "설정" || $0.title == "로그인 시 자동 실행" })
        XCTAssertTrue(menu.items.allSatisfy { $0.submenu == nil })

        // 클릭 전달
        func fire(_ item: NSMenuItem) { _ = item.target!.perform(item.action!, with: item) }
        fire(item)
        fire(menu.items.first { $0.title == "로그아웃" }!)
        fire(menu.items.last!)
        XCTAssertEqual(spy.calls, ["settings", "logout", "quit"])
    }

    func testSettingsItemPresentInEveryAuthState() {
        for auth in [AuthState.signedOut, .expired, .signingIn, .signedIn] {
            let t = titles(build(full, auth: auth))
            let i = t.firstIndex(of: "설정…")
            XCTAssertNotNil(i, "\(auth)")
            // 설정 구획: 인증 항목 바로 뒤, 구분선과 종료 앞
            XCTAssertEqual(t.suffix(3).first, "설정…", "\(auth)")
            XCTAssertEqual(Array(t.suffix(2)), ["---", "종료"], "\(auth)")
        }
    }

    /// 한도 줄 앞 "●" 만 단계 색, 나머지 텍스트는 기본 라벨색.
    func testLimitLinesHaveLevelColoredDot() {
        let u = UsageSnapshot(
            fiveHour: win(49, 3600), weekly: win(80, 86400), fable: win(95, 86400), fetchedAt: now)
        let items = build(u).items
        let expected: [UsageLevel] = [.green, .orange, .red]
        for (item, level) in zip(items.prefix(3), expected) {
            XCTAssertTrue(item.title.hasPrefix("● "), item.title)
            let attr = item.attributedTitle!
            let dot = attr.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
            XCTAssertEqual(dot, level.color, item.title)
            let text = attr.attribute(.foregroundColor, at: 3, effectiveRange: nil) as? NSColor
            XCTAssertEqual(text, NSColor.labelColor, item.title)
        }
        var r = NSRange()
        _ = items[0].attributedTitle!.attribute(.foregroundColor, at: 0, effectiveRange: &r)
        XCTAssertEqual(r, NSRange(location: 0, length: 1)) // 점 하나에만 색
    }

    func testLimitLineDotLevels() {
        func dotLevel(_ pct: Double) -> NSColor {
            let u = UsageSnapshot(weekly: win(pct, 86400), fetchedAt: now)
            return build(u).items[0].attributedTitle!.attribute(.foregroundColor, at: 0, effectiveRange: nil) as! NSColor
        }
        XCTAssertEqual(dotLevel(0), UsageLevel.green.color)
        XCTAssertEqual(dotLevel(50), UsageLevel.yellow.color)
        XCTAssertEqual(dotLevel(79), UsageLevel.yellow.color)
        XCTAssertEqual(dotLevel(94), UsageLevel.orange.color)
        XCTAssertEqual(dotLevel(100), UsageLevel.red.color)
    }

    func testLevelColorsAreDistinctAndYellowDarkerOnLight() {
        let light = NSAppearance(named: .aqua)!, dark = NSAppearance(named: .darkAqua)!
        func rgb(_ c: NSColor, _ a: NSAppearance) -> NSColor {
            var out = c
            a.performAsCurrentDrawingAppearance { out = c.usingColorSpace(.sRGB)! }
            return out
        }
        let y = UsageLevel.yellow.color
        XCTAssertLessThan(rgb(y, light).brightnessComponent, rgb(y, dark).brightnessComponent)
    }

    func testCreditNumberFormatting() {
        XCTAssertEqual(MenuBuilder.number(1234.5), "1,234.5")
        XCTAssertEqual(MenuBuilder.number(100), "100")
        XCTAssertEqual(MenuBuilder.number(0.256), "0.26")
    }
}

final class StatusItemRendererTests: XCTestCase {
    func testLevelThresholdsInclusive() {
        typealias L = UsageLevel
        let cases: [(Double, UsageLevel)] = [
            (0, .green), (10, .green), (49, .green), (49.4, .green),
            (50, .yellow), (79, .yellow), (79.4, .yellow),
            (80, .orange), (94, .orange), (94.4, .orange),
            (95, .red), (100, .red), (120, .red),
            // 표시 퍼센트(반올림) 기준: 79.9% 는 "80%" 로 보이므로 주황
            (49.5, .yellow), (79.9, .orange), (94.5, .red),
        ]
        for (p, expected) in cases { XCTAssertEqual(L.level(forPercent: p), expected, "\(p)") }
    }

    func testLeadingElementsRules() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let full = UsageSnapshot(
            fiveHour: LimitWindow(usedPercent: 50, resetsAt: now.addingTimeInterval(2 * 3600 + 13 * 60)),
            weekly: LimitWindow(usedPercent: 120), fetchedAt: now)
        typealias R = StatusItemRenderer
        XCTAssertEqual(R.leadingElements(usage: full, auth: .signedIn, now: now), [
            .text("2h 13m", .label), .bar(fraction: 0.5, level: .yellow), .bar(fraction: 1, level: .red),
        ])
        var noFive = full; noFive.fiveHour = nil
        XCTAssertEqual(R.leadingElements(usage: noFive, auth: .signedIn, now: now), [.bar(fraction: 1, level: .red)])
        XCTAssertEqual(R.leadingElements(usage: nil, auth: .signedIn, now: now), [.text("–", .label)])
        // 활성 5시간 창 없음(resetsAt == nil): 남은시간 자리 "–", 5h 바는 0%(초록, 채움 없음)
        let inactive = UsageSnapshot(
            fiveHour: LimitWindow(usedPercent: 0, resetsAt: nil), weekly: LimitWindow(usedPercent: 5), fetchedAt: now)
        XCTAssertEqual(R.leadingElements(usage: inactive, auth: .signedIn, now: now), [
            .text("–", .label), .bar(fraction: 0, level: .green), .bar(fraction: 0.05, level: .green),
        ])
        // 5시간 바와 주간 바는 각자 자기 사용률로 색이 정해진다
        let mixed = UsageSnapshot(
            fiveHour: LimitWindow(usedPercent: 85, resetsAt: now.addingTimeInterval(3600)),
            weekly: LimitWindow(usedPercent: 30), fetchedAt: now)
        XCTAssertEqual(Array(R.leadingElements(usage: mixed, auth: .signedIn, now: now).dropFirst()), [
            .bar(fraction: 0.85, level: .orange), .bar(fraction: 0.3, level: .green),
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
