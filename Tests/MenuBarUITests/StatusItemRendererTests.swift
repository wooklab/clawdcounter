import AppKit
import CoreModels
import XCTest
@testable import MenuBarUI

// 클래스명: MenuBuilderTests.swift 에 이미 `StatusItemRendererTests` 가 있어 충돌을 피한다.
@MainActor
final class StatusItemRendererLayoutTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let dark = NSAppearance(named: .darkAqua)!
    private let light = NSAppearance(named: .aqua)!

    private func usage(five: Bool = true) -> UsageSnapshot {
        UsageSnapshot(
            fiveHour: five ? LimitWindow(usedPercent: 42, resetsAt: now.addingTimeInterval(2 * 3600 + 13 * 60)) : nil,
            weekly: LimitWindow(usedPercent: 63, resetsAt: now.addingTimeInterval(3 * 86400)),
            fetchedAt: now)
    }

    private func image(
        _ u: UsageSnapshot?, waiting: Int = 0, auth: AuthState = .signedIn, appearance: NSAppearance? = nil
    ) -> NSImage {
        StatusItemRenderer.image(
            usage: u, sessions: SessionCounts(active: 2, waiting: waiting, idle: 4), auth: auth,
            now: now, appearance: appearance ?? dark)
    }

    func testFiveHourTextHasSpaceBetweenHoursAndMinutes() {
        let els = StatusItemRenderer.leadingElements(usage: usage(), auth: .signedIn, now: now)
        XCTAssertEqual(els.first, .text("2h 13m", .label))
        XCTAssertEqual(TimeFormat.remainingCompact(seconds: 4 * 3600), "4h 00m")
        XCTAssertEqual(TimeFormat.remainingCompact(seconds: 25 * 60), "25m")
    }

    func testBarsAreOrderedFiveHourThenWeekly() {
        let els = StatusItemRenderer.leadingElements(usage: usage(), auth: .signedIn, now: now)
        XCTAssertEqual(els.dropFirst(), [.bar(fraction: 0.42, tone: .normal), .bar(fraction: 0.63, tone: .normal)])
        let weeklyOnly = StatusItemRenderer.leadingElements(usage: usage(five: false), auth: .signedIn, now: now)
        XCTAssertEqual(weeklyOnly, [.bar(fraction: 0.63, tone: .normal)])
    }

    func testImageHeightIsAtMostMenuBarHeightInAllStates() {
        let states: [(UsageSnapshot?, AuthState)] = [
            (usage(), .signedIn), (usage(five: false), .signedIn), (nil, .signedIn),
            (usage(), .signedOut), (usage(), .expired), (usage(), .signingIn),
        ]
        for (u, auth) in states {
            for appearance in [light, dark] {
                for waiting in [0, 1, 3, 12] {
                    let img = image(u, waiting: waiting, auth: auth, appearance: appearance)
                    XCTAssertLessThanOrEqual(img.size.height, 22)
                    XCTAssertEqual(img.size.height, StatusItemRenderer.height)
                    XCTAssertFalse(img.isTemplate)
                    XCTAssertGreaterThan(img.size.width, 20)
                }
            }
        }
    }

    func testWaitingZeroTakesLessWidthThanWaitingPositive() {
        let w0 = image(usage(), waiting: 0).size.width
        let w1 = image(usage(), waiting: 1).size.width
        let w3 = image(usage(), waiting: 3).size.width
        XCTAssertLessThan(w0, w1)
        XCTAssertLessThan(w1, w3) // 2 이상이면 이모지 뒤에 숫자가 붙는다
    }

    func testSignedOutTextIsLeftAndSessionsStillRendered() {
        let out = image(nil, waiting: 0, auth: .signedOut)
        let bars = image(usage(), waiting: 0)
        XCTAssertGreaterThan(out.size.width, 60) // 문구 + 세션 묶음
        XCTAssertNotEqual(out.size.width, bars.size.width)
    }
}
