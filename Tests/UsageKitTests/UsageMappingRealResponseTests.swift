import CoreModels
import XCTest
@testable import UsageKit

/// 실제 응답(Max 5x 계정) 픽스처 및 그 변형 기반 테스트.
final class UsageMappingRealResponseTests: XCTestCase {
    private func map(_ json: String) throws -> UsageMapping.Result {
        try UsageMapping.map(Data(json.utf8), fetchedAt: fixedNow)
    }

    /// Package.swift 에 리소스를 선언하지 않고 `#filePath` 기준으로 읽는다.
    private func fixture(_ name: String, file: StaticString = #filePath) throws -> Data {
        let url = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent(name)
        return try Data(contentsOf: url)
    }

    // 2026-11-14T13:59:59Z
    private let weeklyReset = 1_794_664_799.0

    func testRealResponse() throws {
        let r = try UsageMapping.map(try fixture("usage_real.json"), fetchedAt: fixedNow)
        let s = r.snapshot
        XCTAssertEqual(s.fiveHour, LimitWindow(usedPercent: 0, resetsAt: nil))
        XCTAssertEqual(s.weekly?.usedPercent, 5)
        // 마이크로초(.802996)까지 보존
        XCTAssertEqual(try XCTUnwrap(s.weekly?.resetsAt).timeIntervalSince1970, weeklyReset + 0.802996, accuracy: 0.000_01)
        XCTAssertNil(s.fable)
        XCTAssertEqual(s.credit, CreditUsage(used: 0, total: nil, unit: "USD", isEnabled: false))
        XCTAssertNil(s.resetTickets)
        XCTAssertEqual(s.fetchedAt, fixedNow)
        // null 값 키는 세지 않는다. 남는 것은 null 이 아닌 미사용 키뿐.
        XCTAssertEqual(r.unmappedKeys, [
            "extra_usage.credits_ever_enabled", "extra_usage.spend_limit_reached", "extra_usage.user_disabled",
            "member_dashboard_available", "seven_day_breakdown",
        ])
    }

    // MARK: - limits 폴백

    func testLimitsFallbackWhenTopLevelMissing() throws {
        let r = try map("""
        {"limits": [
          {"kind": "session", "group": "session", "percent": 12, "resets_at": "2026-11-08T12:00:00Z", "scope": null, "is_active": true},
          {"kind": "weekly_all", "group": "weekly", "percent": 5, "resets_at": 1800003600, "scope": null, "is_active": true}
        ]}
        """)
        XCTAssertEqual(r.snapshot.fiveHour, LimitWindow(usedPercent: 12, resetsAt: Date(timeIntervalSince1970: 1_794_139_200)))
        XCTAssertEqual(r.snapshot.weekly, LimitWindow(usedPercent: 5, resetsAt: Date(timeIntervalSince1970: 1_800_003_600)))
        XCTAssertNil(r.snapshot.fable)
        XCTAssertTrue(r.unmappedKeys.isEmpty)
    }

    func testLimitsFallbackWhenTopLevelExplicitNull() throws {
        let r = try map("""
        {"five_hour": null, "seven_day": null,
         "limits": [{"kind": "session", "percent": 0, "resets_at": null, "is_active": false},
                    {"kind": "weekly_all", "percent": 7, "resets_at": null}]}
        """)
        XCTAssertEqual(r.snapshot.fiveHour, LimitWindow(usedPercent: 0, resetsAt: nil))
        XCTAssertEqual(r.snapshot.weekly, LimitWindow(usedPercent: 7, resetsAt: nil))
    }

    func testTopLevelWinsOverLimits() throws {
        let r = try map("""
        {"five_hour": {"utilization": 40, "resets_at": null},
         "limits": [{"kind": "session", "percent": 99, "resets_at": null}]}
        """)
        XCTAssertEqual(r.snapshot.fiveHour?.usedPercent, 40)
    }

    func testExplicitNullFiveHourWithoutSessionLimitMeansNone() throws {
        let r = try map(#"{"five_hour": null, "limits": [{"kind": "weekly_all", "percent": 5, "resets_at": null}]}"#)
        XCTAssertNil(r.snapshot.fiveHour)
        XCTAssertEqual(r.snapshot.weekly?.usedPercent, 5)
    }

    func testWeeklyFallbackIsExactKindOnly() throws {
        let r = try map(#"{"limits": [{"kind": "weekly_opus", "group": "weekly", "percent": 80, "resets_at": null}]}"#)
        XCTAssertNil(r.snapshot.weekly)
    }

    // MARK: - Fable 폴백

    func testFableFromLimitsKind() throws {
        let r = try map("""
        {"seven_day": {"utilization": 5, "resets_at": null},
         "limits": [{"kind": "weekly_all", "percent": 5, "resets_at": null},
                    {"kind": "weekly_fable", "group": "weekly", "percent": 33, "resets_at": 1800003600, "scope": null}]}
        """)
        XCTAssertEqual(r.snapshot.fable, LimitWindow(usedPercent: 33, resetsAt: Date(timeIntervalSince1970: 1_800_003_600)))
        XCTAssertEqual(r.snapshot.weekly?.usedPercent, 5)
    }

    func testFableFromLimitsScopeCaseInsensitive() throws {
        let r = try map(#"{"limits": [{"kind": "weekly_scoped", "percent": 21, "resets_at": null, "scope": "Fable"}]}"#)
        XCTAssertEqual(r.snapshot.fable, LimitWindow(usedPercent: 21, resetsAt: nil))
        XCTAssertNil(r.snapshot.weekly) // fable 항목이 weekly 로 새지 않는다
    }

    func testFableSevenDayKeyWinsOverLimits() throws {
        let r = try map("""
        {"seven_day_fable": {"utilization": 66, "resets_at": null},
         "limits": [{"kind": "weekly_fable", "percent": 10, "resets_at": null}]}
        """)
        XCTAssertEqual(r.snapshot.fable?.usedPercent, 66)
    }

    func testNullFableKeyFallsBackToLimitsAndAbsentMeansNil() throws {
        XCTAssertNil(try map(#"{"seven_day_fable": null, "limits": []}"#).snapshot.fable)
        XCTAssertEqual(try map(#"{"seven_day_fable": null, "limits": [{"kind": "fable", "percent": 4}]}"#).snapshot.fable?.usedPercent, 4)
    }

    // MARK: - 크레딧(spend 가정)

    func testSpendEnabledWithLimit() throws {
        let r = try map("""
        {"spend": {"enabled": true,
                   "used": {"amount_minor": 1234, "currency": "USD", "exponent": 2},
                   "limit": {"amount_minor": 5000, "currency": "USD", "exponent": 2},
                   "cap": null, "balance": null}}
        """)
        XCTAssertEqual(r.snapshot.credit, CreditUsage(used: 12.34, total: 50, unit: "USD"))
        XCTAssertTrue(r.unmappedKeys.isEmpty)
    }

    func testSpendTotalFallbackOrderLimitCapBalance() throws {
        func total(_ extra: String) throws -> Double? {
            try map(#"{"spend": {"enabled": true, "used": {"amount_minor": 100, "currency": "USD", "exponent": 2}, \#(extra)}}"#)
                .snapshot.credit?.total
        }
        XCTAssertEqual(try total(#""limit": null, "cap": {"amount_minor": 2000, "exponent": 2}, "balance": {"amount_minor": 9000, "exponent": 2}"#), 20)
        XCTAssertEqual(try total(#""limit": null, "cap": null, "balance": {"amount_minor": 9000, "exponent": 2}"#), 90)
    }

    func testSpendEnabledButTotalUnknownHasNilTotal() throws {
        let r = try map(#"{"spend": {"enabled": true, "used": {"amount_minor": 100, "currency": "USD", "exponent": 2}, "limit": null, "cap": null, "balance": null}}"#)
        XCTAssertEqual(r.snapshot.credit, CreditUsage(used: 1, total: nil, unit: "USD", isEnabled: true))
    }

    func testSpendEnabledFallsBackToExtraUsageEnabledFlag() throws {
        let used = #""used": {"amount_minor": 100, "currency": "USD", "exponent": 2}"#
        XCTAssertEqual(try map(#"{"spend": {\#(used)}, "extra_usage": {"is_enabled": true}}"#).snapshot.credit?.isEnabled, true)
        XCTAssertEqual(try map(#"{"spend": {\#(used)}, "extra_usage": {"is_enabled": false}}"#).snapshot.credit?.isEnabled, false)
        XCTAssertEqual(try map(#"{"spend": {\#(used), "enabled": false}, "extra_usage": {"is_enabled": true}}"#).snapshot.credit?.isEnabled, false)
    }

    func testSpendWithoutUsedAndNoExtraUsageIsNil() throws {
        XCTAssertNil(try map(#"{"spend": {"enabled": true, "used": null, "limit": {"amount_minor": 5000, "exponent": 2}}}"#).snapshot.credit)
    }

    func testSpendDisabledStillMapsAmountsWithEnabledFalse() throws {
        let r = try map("""
        {"spend": {"enabled": false, "used": {"amount_minor": 100, "currency": "USD", "exponent": 2},
                   "limit": {"amount_minor": 5000, "currency": "USD", "exponent": 2}},
         "extra_usage": {"is_enabled": true, "monthly_limit": 5000, "used_credits": 1}}
        """)
        XCTAssertEqual(r.snapshot.credit, CreditUsage(used: 1, total: 50, unit: "USD", isEnabled: false))
    }

    func testExtraUsageIsAuxiliaryWhenSpendUnusable() throws {
        let r = try map("""
        {"spend": {"enabled": true, "used": null, "limit": null},
         "extra_usage": {"is_enabled": true, "monthly_limit": 5000, "used_credits": 1234.5, "currency": "USD"}}
        """)
        XCTAssertEqual(r.snapshot.credit, CreditUsage(used: 1234.5, total: 5000, unit: "USD"))
    }

    func testExtraUsageRequiresExplicitEnabled() throws {
        XCTAssertNil(try map(#"{"extra_usage": {"monthly_limit": 100, "used_credits": 1}}"#).snapshot.credit)
    }

    // MARK: - 날짜/노이즈

    func testMicrosecondAndOffsetDates() throws {
        XCTAssertEqual(try XCTUnwrap(UsageMapping.date("2026-11-14T13:59:59.802996+00:00")).timeIntervalSince1970,
                       weeklyReset + 0.802996, accuracy: 0.000_01)
        XCTAssertEqual(UsageMapping.date("2026-11-14T13:59:59Z"), Date(timeIntervalSince1970: weeklyReset))
        XCTAssertEqual(UsageMapping.date("2026-11-14T22:59:59+09:00"), Date(timeIntervalSince1970: weeklyReset))
        XCTAssertNil(UsageMapping.date("garbage"))
    }

    func testNullKeysAreNotUnmapped() throws {
        let r = try map(#"{"seven_day": {"utilization": 1, "resets_at": null, "limit_dollars": null, "x": 2}, "tangelo": null, "iguana_necktie": 3}"#)
        XCTAssertEqual(r.unmappedKeys, ["iguana_necktie", "seven_day.x"])
    }
}
