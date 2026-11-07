import XCTest
@testable import MenuBarUI

final class TimeFormatTests: XCTestCase {
    func testRemainingLong() {
        XCTAssertEqual(TimeFormat.remainingLong(seconds: 2 * 3600 + 13 * 60), "2시간 13분")
        XCTAssertEqual(TimeFormat.remainingLong(seconds: 2 * 3600), "2시간")
        XCTAssertEqual(TimeFormat.remainingLong(seconds: 59 * 60 + 59), "59분")
        XCTAssertEqual(TimeFormat.remainingLong(seconds: 45), "1분 미만")
        XCTAssertEqual(TimeFormat.remainingLong(seconds: 0), "곧 초기화")
        XCTAssertEqual(TimeFormat.remainingLong(seconds: -10), "곧 초기화")
        XCTAssertEqual(TimeFormat.remainingLong(seconds: 3 * 86400 + 5 * 3600 + 59 * 60), "3일 5시간")
        XCTAssertEqual(TimeFormat.remainingLong(seconds: 86400), "1일")
        XCTAssertEqual(TimeFormat.remainingLong(seconds: 86400 - 1), "23시간 59분")
    }

    func testRemainingCompact() {
        XCTAssertEqual(TimeFormat.remainingCompact(seconds: 2 * 3600 + 13 * 60), "2h13m")
        XCTAssertEqual(TimeFormat.remainingCompact(seconds: 2 * 3600 + 5 * 60), "2h05m")
        XCTAssertEqual(TimeFormat.remainingCompact(seconds: 4 * 3600), "4h00m")
        XCTAssertEqual(TimeFormat.remainingCompact(seconds: 45 * 60), "45m")
        XCTAssertEqual(TimeFormat.remainingCompact(seconds: 30), "<1m")
        XCTAssertEqual(TimeFormat.remainingCompact(seconds: -1), "0m")
        XCTAssertEqual(TimeFormat.remainingCompact(seconds: 86400 + 3 * 3600), "1d3h")
    }

    func testRemainingPhrase() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertNil(TimeFormat.remainingPhrase(until: nil, now: now))
        XCTAssertEqual(TimeFormat.remainingPhrase(until: now.addingTimeInterval(3600 + 60), now: now), "남은 1시간 1분")
        XCTAssertEqual(TimeFormat.remainingPhrase(until: now.addingTimeInterval(-5), now: now), "곧 초기화")
    }
}
