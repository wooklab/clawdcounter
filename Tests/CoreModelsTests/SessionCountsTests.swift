import XCTest
import CoreModels

final class SessionCountsTests: XCTestCase {
    func testNamesInitMapsToRefsWithoutPid() {
        let s = SessionCounts(active: 2, waiting: 0, idle: 1, activeNames: ["a", "b"], idleNames: ["c"])
        XCTAssertEqual(s.activeSessions, [SessionRef(name: "a"), SessionRef(name: "b")])
        XCTAssertEqual(s.activeNames, ["a", "b"])
        XCTAssertEqual(s.waitingNames, [])
        XCTAssertEqual(s.idleNames, ["c"])
        XCTAssertEqual(SessionCounts(active: 0, waiting: 0, idle: 0).activeSessions, [])
    }

    func testEqualityIncludesPid() {
        let a = SessionCounts(active: 1, waiting: 0, idle: 0, activeSessions: [SessionRef(name: "x", pid: 1)], waitingSessions: [], idleSessions: [])
        let b = SessionCounts(active: 1, waiting: 0, idle: 0, activeSessions: [SessionRef(name: "x", pid: 2)], waitingSessions: [], idleSessions: [])
        XCTAssertNotEqual(a, b)
    }

    func testFocusPidUsesParentForSubagent() {
        XCTAssertEqual(SessionRef(name: "s", pid: 5).focusPid, 5)
        XCTAssertEqual(SessionRef(name: "↳ x", pid: nil, isSubagent: true, parentPid: 9).focusPid, 9)
        XCTAssertNil(SessionRef(name: "↳ x", isSubagent: true).focusPid)
        XCTAssertNil(SessionRef(name: "n").focusPid)
    }
}
