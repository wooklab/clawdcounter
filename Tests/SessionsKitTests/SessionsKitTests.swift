import XCTest
import CoreModels
@testable import SessionsKit

// MARK: - 헬퍼

private final class Emissions: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SessionCounts] = []
    var all: [SessionCounts] { lock.lock(); defer { lock.unlock() }; return values }
    var latest: SessionCounts? { all.last }
    func append(_ v: SessionCounts) { lock.lock(); values.append(v); lock.unlock() }
}

private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("sessionskit-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func spawnSleeper() throws -> Process {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sleep")
    p.arguments = ["120"]
    try p.run()
    return p
}

/// 이미 종료·회수된 프로세스의 pid.
private func deadPid() throws -> Int {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try p.run()
    p.waitUntilExit()
    return Int(p.processIdentifier)
}

private func write(_ dir: URL, pid: Int, status: String?, procStart: String? = nil, atomic: Bool = true) throws {
    var obj: [String: Any] = ["pid": pid, "sessionId": "s-\(pid)", "kind": "interactive"]
    if let status { obj["status"] = status }
    if let procStart { obj["procStart"] = procStart }
    let data = try JSONSerialization.data(withJSONObject: obj)
    try data.write(to: dir.appendingPathComponent("\(pid).json"), options: atomic ? .atomic : [])
}

private func waitUntil(timeout: TimeInterval = 5, _ cond: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if cond() { return true }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return cond()
}

private func counts(_ a: Int, _ w: Int, _ i: Int) -> SessionCounts { SessionCounts(active: a, waiting: w, idle: i) }

private func formatProcStart(_ date: Date, utc: Bool) -> String {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = utc ? TimeZone(identifier: "UTC")! : .current
    let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    let days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    let wd = days[cal.component(.weekday, from: date) - 1]
    return String(format: "%@ %@ %2d %02d:%02d:%02d %d", wd, months[c.month! - 1], c.day!, c.hour!, c.minute!, c.second!, c.year!)
}

// MARK: - 테스트

final class SessionMonitorTests: XCTestCase {
    private func monitor(_ dir: URL, mapping: StatusMapping = .default) -> SessionMonitor {
        SessionMonitor(directory: dir, statusMapping: mapping, debounce: 0.1, rescanInterval: 60)
    }

    private func collect(_ m: SessionMonitor) -> (Emissions, Task<Void, Never>) {
        let e = Emissions()
        let stream = m.countsStream()
        let task = Task { for await c in stream { e.append(c) } }
        return (e, task)
    }

    func testClassifiesStatuses() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let procs = try (0..<5).map { _ in try spawnSleeper() }
        defer { procs.forEach { $0.terminate() } }
        let pids = procs.map { Int($0.processIdentifier) }
        for (pid, status) in zip(pids, ["busy", "shell", "waiting", "idle", "idle"]) {
            try write(dir, pid: pid, status: status)
        }
        let m = monitor(dir)
        let (e, task) = collect(m)
        m.start(); defer { m.stop(); task.cancel() }
        let ok = await waitUntil { e.latest == counts(2, 1, 2) }
        XCTAssertTrue(ok, "emitted: \(e.all)")
    }

    func testUnknownAndMissingStatusTreatedAsIdle() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let procs = try (0..<2).map { _ in try spawnSleeper() }
        defer { procs.forEach { $0.terminate() } }
        try write(dir, pid: Int(procs[0].processIdentifier), status: "weird-new-value")
        try write(dir, pid: Int(procs[1].processIdentifier), status: nil)
        let m = monitor(dir)
        let (e, task) = collect(m)
        m.start(); defer { m.stop(); task.cancel() }
        let ok = await waitUntil { e.latest == counts(0, 0, 2) }
        XCTAssertTrue(ok, "emitted: \(e.all)")
    }

    func testCustomMappingRemapsStatus() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = try spawnSleeper(); defer { p.terminate() }
        try write(dir, pid: Int(p.processIdentifier), status: "needs_input")
        let m = monitor(dir, mapping: StatusMapping(waiting: ["waiting", "needs_input"]))
        let (e, task) = collect(m)
        m.start(); defer { m.stop(); task.cancel() }
        let ok = await waitUntil { e.latest == counts(0, 1, 0) }
        XCTAssertTrue(ok, "emitted: \(e.all)")
    }

    func testDeadPidExcluded() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let alive = try spawnSleeper(); defer { alive.terminate() }
        try write(dir, pid: Int(alive.processIdentifier), status: "busy")
        try write(dir, pid: try deadPid(), status: "busy")
        let m = monitor(dir)
        let (e, task) = collect(m)
        m.start(); defer { m.stop(); task.cancel() }
        let ok = await waitUntil { e.latest == counts(1, 0, 0) }
        XCTAssertTrue(ok, "emitted: \(e.all)")
    }

    func testEPERMPidCountsAsAlive() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(dir, pid: 1, status: "idle") // launchd: kill(1, 0) == EPERM
        XCTAssertTrue(ProcessProbe.isAlive(1))
        let m = monitor(dir)
        let (e, task) = collect(m)
        m.start(); defer { m.stop(); task.cancel() }
        let ok = await waitUntil { e.latest == counts(0, 0, 1) }
        XCTAssertTrue(ok, "emitted: \(e.all)")
    }

    func testPidReuseDetectedByProcStart() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let procs = try (0..<3).map { _ in try spawnSleeper() }
        defer { procs.forEach { $0.terminate() } }
        let start = try XCTUnwrap(ProcessProbe.startTime(of: Int(procs[0].processIdentifier)))
        // 일치(UTC 표기), 일치(로컬 표기), 불일치(재사용된 pid 가정)
        try write(dir, pid: Int(procs[0].processIdentifier), status: "busy", procStart: formatProcStart(start, utc: true))
        try write(dir, pid: Int(procs[1].processIdentifier), status: "busy", procStart: formatProcStart(ProcessProbe.startTime(of: Int(procs[1].processIdentifier))!, utc: false))
        try write(dir, pid: Int(procs[2].processIdentifier), status: "busy", procStart: "Mon Jan  1 00:00:00 2001")
        let m = monitor(dir)
        let (e, task) = collect(m)
        m.start(); defer { m.stop(); task.cancel() }
        let ok = await waitUntil { e.latest == counts(2, 0, 0) }
        XCTAssertTrue(ok, "emitted: \(e.all)")
    }

    func testUnparseableProcStartDoesNotExclude() {
        XCTAssertNil(ProcessProbe.procStartMatches("garbage", actualStart: Date()))
    }

    func testIgnoresKeyFilesAndBrokenJSON() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let procs = try (0..<3).map { _ in try spawnSleeper() }
        defer { procs.forEach { $0.terminate() } }
        let pids = procs.map { Int($0.processIdentifier) }
        try write(dir, pid: pids[0], status: "busy")
        try Data("{\"pid\":1,\"status\":\"bu".utf8).write(to: dir.appendingPathComponent("\(pids[1]).json")) // 부분 쓰기
        try Data("[1,2,3]".utf8).write(to: dir.appendingPathComponent("\(pids[2]).json"))                    // 객체 아님
        try Data("secret".utf8).write(to: dir.appendingPathComponent("\(pids[0]).abcdef.key"))
        try Data("{}".utf8).write(to: dir.appendingPathComponent("notapid.json"))
        try Data().write(to: dir.appendingPathComponent("0.json"))
        let m = monitor(dir)
        let (e, task) = collect(m)
        m.start(); defer { m.stop(); task.cancel() }
        let ok = await waitUntil { e.latest == counts(1, 0, 0) }
        XCTAssertTrue(ok, "emitted: \(e.all)")
    }

    func testMissingDirectoryYieldsZero() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString)")
        let m = monitor(dir)
        let (e, task) = collect(m)
        m.start(); defer { m.stop(); task.cancel() }
        let ok = await waitUntil { e.latest == counts(0, 0, 0) }
        XCTAssertTrue(ok, "emitted: \(e.all)")
    }

    func testEmitsOnDirectoryChangesAndDedupes() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let procs = try (0..<2).map { _ in try spawnSleeper() }
        defer { procs.forEach { $0.terminate() } }
        let pids = procs.map { Int($0.processIdentifier) }

        let m = monitor(dir)
        let (e, task) = collect(m)
        m.start(); defer { m.stop(); task.cancel() }
        var ok = await waitUntil { e.latest == counts(0, 0, 0) }
        XCTAssertTrue(ok, "initial: \(e.all)")

        // 새 파일
        try write(dir, pid: pids[0], status: "idle")
        ok = await waitUntil { e.latest == counts(0, 0, 1) }
        XCTAssertTrue(ok, "new file: \(e.all)")

        // 제자리(비원자) 수정: idle -> busy
        try write(dir, pid: pids[0], status: "busy", atomic: false)
        ok = await waitUntil { e.latest == counts(1, 0, 0) }
        XCTAssertTrue(ok, "in-place edit: \(e.all)")

        // 원자적 교체: busy -> waiting
        try write(dir, pid: pids[0], status: "waiting", atomic: true)
        ok = await waitUntil { e.latest == counts(0, 1, 0) }
        XCTAssertTrue(ok, "atomic replace: \(e.all)")

        // 결과가 같은 변경은 emit 안 함
        let before = e.all.count
        try write(dir, pid: pids[0], status: "waiting", atomic: false)
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(e.all.count, before, "unchanged counts must not re-emit: \(e.all)")

        // 삭제
        try FileManager.default.removeItem(at: dir.appendingPathComponent("\(pids[0]).json"))
        ok = await waitUntil { e.latest == counts(0, 0, 0) }
        XCTAssertTrue(ok, "delete: \(e.all)")
    }

    func testPeriodicRescanDropsDeadPid() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = try spawnSleeper()
        try write(dir, pid: Int(p.processIdentifier), status: "busy")
        let m = SessionMonitor(directory: dir, statusMapping: .default, debounce: 0.1, rescanInterval: 0.3)
        let (e, task) = collect(m)
        m.start(); defer { m.stop(); task.cancel() }
        var ok = await waitUntil { e.latest == counts(1, 0, 0) }
        XCTAssertTrue(ok, "alive: \(e.all)")
        p.terminate(); p.waitUntilExit() // 파일 변경 없이 프로세스만 종료
        ok = await waitUntil { e.latest == counts(0, 0, 0) }
        XCTAssertTrue(ok, "after death: \(e.all)")
    }

    func testReplaysLatestToLateSubscriber() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = try spawnSleeper(); defer { p.terminate() }
        try write(dir, pid: Int(p.processIdentifier), status: "busy")
        let m = monitor(dir)
        m.start(); defer { m.stop() }
        let (e, task) = collect(m) // start 이후 구독
        defer { task.cancel() }
        let ok = await waitUntil { e.latest == counts(1, 0, 0) }
        XCTAssertTrue(ok, "emitted: \(e.all)")
    }

    func testStopHaltsUpdates() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = try spawnSleeper(); defer { p.terminate() }
        let m = monitor(dir)
        let (e, task) = collect(m)
        m.start(); defer { task.cancel() }
        var ok = await waitUntil { e.latest == counts(0, 0, 0) }
        XCTAssertTrue(ok)
        m.stop()
        try write(dir, pid: Int(p.processIdentifier), status: "busy")
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(e.latest, counts(0, 0, 0))
        m.start() // 재시작 가능
        ok = await waitUntil { e.latest == counts(1, 0, 0) }
        m.stop()
        XCTAssertTrue(ok, "restart: \(e.all)")
    }

    /// stop() 없이 해제: 크래시 없이 해제되고, 해제 후에는 emit이 없어야 한다.
    func testReleaseWithoutStopIsSafeAndSilent() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = try spawnSleeper(); defer { p.terminate() }
        let e = Emissions()
        var task: Task<Void, Never>?
        weak var weakMonitor: SessionMonitor?
        do {
            let m = monitor(dir)
            weakMonitor = m
            let stream = m.countsStream()
            task = Task { for await c in stream { e.append(c) } }
            m.start() // stop() 호출 없이 스코프 종료
            let ok = await waitUntil { e.latest == counts(0, 0, 0) }
            XCTAssertTrue(ok, "initial: \(e.all)")
        }
        defer { task?.cancel() }
        let released = await waitUntil { weakMonitor == nil }
        XCTAssertTrue(released, "monitor must be deallocated without stop()")
        let before = e.all.count
        for i in 0..<20 { // 해제 직후 이벤트 폭주
            try write(dir, pid: Int(p.processIdentifier), status: i.isMultiple(of: 2) ? "busy" : "idle", atomic: false)
        }
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(e.all.count, before, "no emission after release: \(e.all)")
    }
}

final class FSEventsWatcherTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
        func inc() { lock.lock(); n += 1; lock.unlock() }
    }

    func testDeinitWithoutStopStopsCallbacks() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let queue = DispatchQueue(label: "test.fsevents")
        let counter = Counter()
        var watcher: FSEventsWatcher? = FSEventsWatcher(path: dir.path, queue: queue) { counter.inc() }
        queue.sync { watcher?.start() }
        try Data("a".utf8).write(to: dir.appendingPathComponent("a.txt"))
        let fired = await waitUntil { counter.value > 0 }
        XCTAssertTrue(fired, "watcher should fire while alive")

        watcher = nil // 큐 밖 스레드에서 deinit, stop() 없음
        queue.sync {}  // 이미 큐에 들어간 콜백 배출
        let before = counter.value
        for i in 0..<10 { try Data("b\(i)".utf8).write(to: dir.appendingPathComponent("b\(i).txt")) }
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(counter.value, before, "no callback after deinit")
    }
}
