import CoreModels
import XCTest
@testable import UsageKit

final class UsageMappingTests: XCTestCase {
    private func map(_ json: String) throws -> UsageMapping.Result {
        try UsageMapping.map(Data(json.utf8), fetchedAt: fixedNow)
    }

    func testFullShapeWithFiveHour() throws {
        let r = try map("""
        {
          "five_hour": {"utilization": 37.5, "resets_at": "2026-11-08T12:00:00.123456+00:00"},
          "seven_day": {"utilization": 12, "resets_at": "2026-11-12T00:00:00Z"},
          "seven_day_opus": null,
          "seven_day_sonnet": {"utilization": 3.0, "resets_at": null},
          "extra_usage": {"is_enabled": true, "monthly_limit": 5000, "used_credits": 1234.5, "utilization": 24.69}
        }
        """)
        let s = r.snapshot
        XCTAssertEqual(s.fiveHour?.usedPercent, 37.5)
        XCTAssertEqual(s.fiveHour?.resetsAt?.timeIntervalSince1970 ?? 0, 1_794_139_200.123, accuracy: 0.01)
        XCTAssertEqual(s.weekly?.usedPercent, 12)
        XCTAssertEqual(s.weekly?.resetsAt, Date(timeIntervalSince1970: 1_794_441_600))
        XCTAssertNil(s.fable)
        XCTAssertEqual(s.credit, CreditUsage(used: 1234.5, total: 5000))
        XCTAssertNil(s.resetTickets)
        XCTAssertEqual(s.fetchedAt, fixedNow)
        XCTAssertEqual(r.unmappedKeys, ["seven_day_opus", "seven_day_sonnet"])
    }

    func testNoFiveHourPlan() throws {
        let r = try map(#"{"five_hour": null, "seven_day": {"utilization": 50, "resets_at": 1800003600}}"#)
        XCTAssertNil(r.snapshot.fiveHour)
        XCTAssertEqual(r.snapshot.weekly, LimitWindow(usedPercent: 50, resetsAt: Date(timeIntervalSince1970: 1_800_003_600)))
        XCTAssertTrue(r.unmappedKeys.isEmpty)
    }

    func testMissingFiveHourKeyAndAllNull() throws {
        let r = try map(#"{"seven_day": null, "extra_usage": null}"#)
        XCTAssertNil(r.snapshot.fiveHour)
        XCTAssertNil(r.snapshot.weekly)
        XCTAssertNil(r.snapshot.credit)
    }

    func testEmptyObject() throws {
        let r = try map("{}")
        XCTAssertEqual(r.snapshot, UsageSnapshot(fetchedAt: fixedNow))
    }

    func testAlternatePercentKeyAndEpochMillis() throws {
        let r = try map(#"{"five_hour": {"used_percentage": 80, "resets_at": 1800003600000}}"#)
        XCTAssertEqual(r.snapshot.fiveHour, LimitWindow(usedPercent: 80, resetsAt: Date(timeIntervalSince1970: 1_800_003_600)))
    }

    func testWindowWithNullFieldsAndMissingPercent() throws {
        let r = try map(#"{"five_hour": {"utilization": null, "resets_at": null}, "seven_day": {"resets_at": "2026-11-12T00:00:00Z"}}"#)
        XCTAssertNil(r.snapshot.fiveHour)
        XCTAssertNil(r.snapshot.weekly)
    }

    func testPercentWithoutResetTime() throws {
        let r = try map(#"{"seven_day": {"utilization": 9, "resets_at": null}}"#)
        XCTAssertEqual(r.snapshot.weekly, LimitWindow(usedPercent: 9, resetsAt: nil))
    }

    func testFableWeeklyKey() throws {
        let r = try map(#"{"seven_day": {"utilization": 1}, "seven_day_fable": {"utilization": 66, "resets_at": 1800003600}}"#)
        XCTAssertEqual(r.snapshot.fable?.usedPercent, 66)
        XCTAssertTrue(r.unmappedKeys.isEmpty)
    }

    func testUnknownKeysReportedByNameOnly() throws {
        let r = try map("""
        {"seven_day": {"utilization": 5, "resets_at": null, "surprise": "SECRET-VALUE"},
         "iguana_necktie": {"x": 1}, "extra_usage": {"is_enabled": false, "weird": 1}}
        """)
        XCTAssertEqual(r.unmappedKeys, ["extra_usage.weird", "iguana_necktie", "seven_day.surprise"])
        XCTAssertFalse(r.unmappedKeys.joined().contains("SECRET"))
    }

    func testExtraUsageDisabledOrIncomplete() throws {
        XCTAssertNil(try map(#"{"extra_usage": {"is_enabled": false, "monthly_limit": 100, "used_credits": 1}}"#).snapshot.credit)
        XCTAssertNil(try map(#"{"extra_usage": {"is_enabled": true, "monthly_limit": null, "used_credits": null}}"#).snapshot.credit)
    }

    func testBoolIsNotANumber() throws {
        XCTAssertNil(try map(#"{"seven_day": {"utilization": true}}"#).snapshot.weekly)
    }

    func testTicketHeuristic() throws {
        XCTAssertEqual(try map(#"{"reset_tickets": {"remaining": 2, "total": 3}}"#).snapshot.resetTickets,
                       ResetTicketStatus(remaining: 2, total: 3))
        XCTAssertEqual(try map(#"{"session_reset_ticket_count": 1}"#).snapshot.resetTickets,
                       ResetTicketStatus(remaining: 1))
    }

    func testNonObjectThrows() {
        XCTAssertThrowsError(try map("[1,2]")) { XCTAssertEqual($0 as? UsageError, .invalidResponse) }
        XCTAssertThrowsError(try map("not json")) { XCTAssertEqual($0 as? UsageError, .invalidResponse) }
    }
}
