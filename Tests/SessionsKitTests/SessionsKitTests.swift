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
    // waitUntilExit()는 async 테스트(협력 스레드)에서 깨어나지 못해 무한 대기할 수 있다 → 상한 있는 폴링.
    let deadline = Date().addingTimeInterval(5)
    while p.isRunning, Date() < deadline { usleep(10_000) }
    return Int(p.processIdentifier)
}

private func write(
    _ dir: URL, pid: Int, status: String?, procStart: String? = nil, name: String? = nil, cwd: String? = nil,
    entrypoint: String? = nil, atomic: Bool = true
) throws {
    var obj: [String: Any] = ["pid": pid, "sessionId": "s-\(pid)", "kind": "interactive"]
    if let status { obj["status"] = status }
    if let name { obj["name"] = name }
    if let cwd { obj["cwd"] = cwd }
    if let entrypoint { obj["entrypoint"] = entrypoint }
    if let procStart { obj["procStart"] = procStart }
    let data = try JSONSerialization.data(withJSONObject: obj)
    try data.write(to: dir.appendingPathComponent("\(pid).json"), options: atomic ? .atomic : [])
}

/// 테스트가 실제 `~/.claude/projects` 를 감시/스캔하지 않도록 주입하는 존재하지 않는 경로.
private func noProjectsDir() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("sessionskit-noprojects-\(UUID().uuidString)", isDirectory: true)
}

private func waitUntil(timeout: TimeInterval = 5, _ cond: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if cond() { return true }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return cond()
}

private extension SessionCounts {
    var numbers: [Int] { [active, waiting, idle] }
}

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
        SessionMonitor(directory: dir, projectsDirectory: noProjectsDir(), statusMapping: mapping, debounce: 0.1, rescanInterval: 60)
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
        let ok = await waitUntil { e.latest?.numbers == [2, 1, 2] }
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
        let ok = await waitUntil { e.latest?.numbers == [0, 0, 2] }
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
        let ok = await waitUntil { e.latest?.numbers == [0, 1, 0] }
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
        let ok = await waitUntil { e.latest?.numbers == [1, 0, 0] }
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
        let ok = await waitUntil { e.latest?.numbers == [0, 0, 1] }
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
        let ok = await waitUntil { e.latest?.numbers == [2, 0, 0] }
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
        let ok = await waitUntil { e.latest?.numbers == [1, 0, 0] }
        XCTAssertTrue(ok, "emitted: \(e.all)")
    }

    func testMissingDirectoryYieldsZero() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString)")
        let m = monitor(dir)
        let (e, task) = collect(m)
        m.start(); defer { m.stop(); task.cancel() }
        let ok = await waitUntil { e.latest?.numbers == [0, 0, 0] }
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
        var ok = await waitUntil { e.latest?.numbers == [0, 0, 0] }
        XCTAssertTrue(ok, "initial: \(e.all)")

        // 새 파일
        try write(dir, pid: pids[0], status: "idle")
        ok = await waitUntil { e.latest?.numbers == [0, 0, 1] }
        XCTAssertTrue(ok, "new file: \(e.all)")

        // 제자리(비원자) 수정: idle -> busy
        try write(dir, pid: pids[0], status: "busy", atomic: false)
        ok = await waitUntil { e.latest?.numbers == [1, 0, 0] }
        XCTAssertTrue(ok, "in-place edit: \(e.all)")

        // 원자적 교체: busy -> waiting
        try write(dir, pid: pids[0], status: "waiting", atomic: true)
        ok = await waitUntil { e.latest?.numbers == [0, 1, 0] }
        XCTAssertTrue(ok, "atomic replace: \(e.all)")

        // 결과가 같은 변경은 emit 안 함
        let before = e.all.count
        try write(dir, pid: pids[0], status: "waiting", atomic: false)
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(e.all.count, before, "unchanged counts must not re-emit: \(e.all)")

        // 삭제
        try FileManager.default.removeItem(at: dir.appendingPathComponent("\(pids[0]).json"))
        ok = await waitUntil { e.latest?.numbers == [0, 0, 0] }
        XCTAssertTrue(ok, "delete: \(e.all)")
    }

    func testPeriodicRescanDropsDeadPid() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = try spawnSleeper()
        try write(dir, pid: Int(p.processIdentifier), status: "busy")
        let m = SessionMonitor(directory: dir, projectsDirectory: noProjectsDir(), statusMapping: .default, debounce: 0.1, rescanInterval: 0.3)
        let (e, task) = collect(m)
        m.start(); defer { m.stop(); task.cancel() }
        var ok = await waitUntil { e.latest?.numbers == [1, 0, 0] }
        XCTAssertTrue(ok, "alive: \(e.all)")
        p.terminate() // 파일 변경 없이 프로세스만 종료
        // waitUntilExit()는 협력 스레드에서 종료 알림을 못 받아 영구 대기한 적이 있다(간헐 행) → 상한 있는 폴링.
        let exited = await waitUntil { !p.isRunning }
        XCTAssertTrue(exited, "sleeper did not exit")
        ok = await waitUntil { e.latest?.numbers == [0, 0, 0] }
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
        let ok = await waitUntil { e.latest?.numbers == [1, 0, 0] }
        XCTAssertTrue(ok, "emitted: \(e.all)")
    }

    func testStopHaltsUpdates() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = try spawnSleeper(); defer { p.terminate() }
        let m = monitor(dir)
        let (e, task) = collect(m)
        m.start(); defer { task.cancel() }
        var ok = await waitUntil { e.latest?.numbers == [0, 0, 0] }
        XCTAssertTrue(ok)
        m.stop()
        try write(dir, pid: Int(p.processIdentifier), status: "busy")
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(e.latest?.numbers, [0, 0, 0])
        m.start() // 재시작 가능
        ok = await waitUntil { e.latest?.numbers == [1, 0, 0] }
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
            let ok = await waitUntil { e.latest?.numbers == [0, 0, 0] }
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

final class SessionNamesTests: XCTestCase {
    private func monitor(_ dir: URL) -> SessionMonitor {
        SessionMonitor(directory: dir, projectsDirectory: noProjectsDir(), statusMapping: .default, debounce: 0.1, rescanInterval: 60)
    }

    func testDisplayNameFallbackRules() {
        typealias M = SessionMonitor
        XCTAssertEqual(M.displayName(name: "내 세션", cwd: "/a/b"), "내 세션")
        XCTAssertEqual(M.displayName(name: "  내 세션 \n", cwd: "/a/b"), "내 세션")
        XCTAssertEqual(M.displayName(name: "", cwd: "/a/proj"), "proj")
        XCTAssertEqual(M.displayName(name: "   ", cwd: "/a/proj/"), "proj")
        XCTAssertEqual(M.displayName(name: nil, cwd: "/a/proj"), "proj")
        // 이름을 정할 수 없으면 nil: UI 가 `.unnamed` 대체 표시명을 언어별로 그린다.
        XCTAssertNil(M.displayName(name: nil, cwd: "/"))
        XCTAssertNil(M.displayName(name: nil, cwd: ""))
        XCTAssertNil(M.displayName(name: nil, cwd: nil))
    }

    func testNamesGroupedByStatusSortedWithFallbacks() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let procs = try (0..<6).map { _ in try spawnSleeper() }
        defer { procs.forEach { $0.terminate() } }
        let p = procs.map { Int($0.processIdentifier) }
        try write(dir, pid: p[0], status: "busy", name: "beta")
        try write(dir, pid: p[1], status: "shell", name: "Alpha")
        try write(dir, pid: p[2], status: "waiting", name: "", cwd: "/work/clawdcounter")
        try write(dir, pid: p[3], status: "idle")                                  // 이름·cwd 없음
        try write(dir, pid: p[4], status: "idle", name: "세션 10")
        try write(dir, pid: p[5], status: "idle", name: "세션 2")                   // 숫자 순서: 2 < 10
        let m = monitor(dir)
        let e = Emissions()
        let stream = m.countsStream()
        let task = Task { for await c in stream { e.append(c) } }
        m.start(); defer { m.stop(); task.cancel() }
        let ok = await waitUntil { e.latest?.numbers == [2, 1, 3] }
        XCTAssertTrue(ok, "emitted: \(e.all)")
        let latest = try XCTUnwrap(e.latest)
        XCTAssertEqual(latest.activeNames, ["Alpha", "beta"])
        XCTAssertEqual(latest.waitingNames, ["clawdcounter"])
        XCTAssertEqual(latest.idleNames, ["세션 2", "세션 10", ""]) // 이름 없는 세션은 맨 뒤
        XCTAssertEqual(latest.idleSessions.map(\.placeholder), [nil, nil, .unnamed])
    }

    func testEqualNamesOrderedByPid() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let procs = try (0..<3).map { _ in try spawnSleeper() }
        defer { procs.forEach { $0.terminate() } }
        for proc in procs { try write(dir, pid: Int(proc.processIdentifier), status: "idle", name: "same") }
        let m = monitor(dir)
        let e = Emissions()
        let stream = m.countsStream()
        let task = Task { for await c in stream { e.append(c) } }
        m.start(); defer { m.stop(); task.cancel() }
        let ok = await waitUntil { e.latest?.numbers == [0, 0, 3] }
        XCTAssertTrue(ok, "emitted: \(e.all)")
        XCTAssertEqual(e.latest?.idleNames, ["same", "same", "same"])
    }

    /// 상태·개수가 같아도 이름만 바뀌면 emit 한다.
    func testRenameAloneEmits() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let proc = try spawnSleeper(); defer { proc.terminate() }
        let pid = Int(proc.processIdentifier)
        try write(dir, pid: pid, status: "idle", name: "old")
        let m = monitor(dir)
        let e = Emissions()
        let stream = m.countsStream()
        let task = Task { for await c in stream { e.append(c) } }
        m.start(); defer { m.stop(); task.cancel() }
        var ok = await waitUntil { e.latest?.idleNames == ["old"] }
        XCTAssertTrue(ok, "initial: \(e.all)")
        try write(dir, pid: pid, status: "idle", name: "new")
        ok = await waitUntil { e.latest?.idleNames == ["new"] }
        XCTAssertTrue(ok, "rename: \(e.all)")
        XCTAssertEqual(e.latest?.numbers, [0, 0, 1])
    }

    func testDeadPidNameExcluded() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let alive = try spawnSleeper(); defer { alive.terminate() }
        try write(dir, pid: Int(alive.processIdentifier), status: "busy", name: "alive")
        try write(dir, pid: try deadPid(), status: "busy", name: "dead")
        let m = monitor(dir)
        let e = Emissions()
        let stream = m.countsStream()
        let task = Task { for await c in stream { e.append(c) } }
        m.start(); defer { m.stop(); task.cancel() }
        let ok = await waitUntil { e.latest?.activeNames == ["alive"] }
        XCTAssertTrue(ok, "emitted: \(e.all)")
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

    func testPathFilterSkipsUnmatchedChanges() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let queue = DispatchQueue(label: "test.fsevents.filter")
        let counter = Counter()
        let watcher = FSEventsWatcher(path: dir.path, queue: queue, pathFilter: SessionMonitor.isSubagentPath) { counter.inc() }
        queue.sync { watcher.start() }
        defer { queue.sync { watcher.stop() } }

        // 대화 기록처럼 subagents 밖에서 쓰이는 파일은 콜백을 일으키지 않는다.
        let session = dir.appendingPathComponent("-proj/s-1", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        for i in 0..<5 { try Data("{}\n".utf8).write(to: dir.appendingPathComponent("-proj/s-\(i).jsonl")) }
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(counter.value, 0, "non-subagent changes must be filtered out")

        let sub = session.appendingPathComponent("subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: sub.appendingPathComponent("agent-a.meta.json"))
        let fired = await waitUntil { counter.value > 0 }
        XCTAssertTrue(fired, "subagent changes must fire")
    }

    func testIsSubagentPath() {
        XCTAssertTrue(SessionMonitor.isSubagentPath("/p/-proj/s1/subagents"))
        XCTAssertTrue(SessionMonitor.isSubagentPath("/p/-proj/s1/subagents/agent-a.meta.json"))
        XCTAssertFalse(SessionMonitor.isSubagentPath("/p/-proj/s1.jsonl"))
        XCTAssertFalse(SessionMonitor.isSubagentPath("/p/-proj/my-subagents-notes.md"))
    }
}

// MARK: - 서브에이전트

final class SubagentCountingTests: XCTestCase {
    private func monitor(_ dir: URL, _ projects: URL, rescan: TimeInterval = 60) -> SessionMonitor {
        SessionMonitor(directory: dir, projectsDirectory: projects, statusMapping: .default, debounce: 0.1, rescanInterval: rescan)
    }

    private func collect(_ m: SessionMonitor) -> (Emissions, Task<Void, Never>) {
        let e = Emissions()
        let stream = m.countsStream()
        let task = Task { for await c in stream { e.append(c) } }
        return (e, task)
    }

    /// `<projects>/<project>/s-<pid>/subagents/agent-<id>.{meta.json,jsonl}`. `age` 초 전으로 mtime 설정.
    @discardableResult
    private func writeAgent(
        _ projects: URL, parentPid: Int, id: String, description: String? = "작업", finished: Bool? = nil,
        depth: Int = 1, age: TimeInterval = 0, project: String = "-proj", withJsonl: Bool = true
    ) throws -> URL {
        let dir = projects.appendingPathComponent(project).appendingPathComponent("s-\(parentPid)").appendingPathComponent("subagents")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var obj: [String: Any] = ["agentType": "general-purpose", "spawnDepth": depth, "requestShape": "background"]
        if let description { obj["description"] = description }
        if let finished { obj["finished"] = finished }
        let meta = dir.appendingPathComponent("agent-\(id).meta.json")
        try JSONSerialization.data(withJSONObject: obj).write(to: meta)
        var files = [meta]
        if withJsonl {
            let jsonl = dir.appendingPathComponent("agent-\(id).jsonl")
            try Data("{}\n".utf8).write(to: jsonl)
            files.append(jsonl)
        }
        let date = Date().addingTimeInterval(-age)
        for f in files { try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: f.path) }
        return meta
    }

    func testRunningSubagentsAddedToActiveWithNames() async throws {
        let (dir, projects) = (try makeTempDir(), try makeTempDir())
        defer { [dir, projects].forEach { try? FileManager.default.removeItem(at: $0) } }
        let p = try spawnSleeper(); defer { p.terminate() }
        let pid = Int(p.processIdentifier)
        try write(dir, pid: pid, status: "idle", name: "부모")
        try writeAgent(projects, parentPid: pid, id: "b", description: "Zeta 작업")
        try writeAgent(projects, parentPid: pid, id: "a", description: "alpha 작업")
        let m = monitor(dir, projects)
        let (e, task) = collect(m)
        m.start(); defer { m.stop(); task.cancel() }
        let ok = await waitUntil { e.latest?.numbers == [2, 0, 1] }
        XCTAssertTrue(ok, "emitted: \(e.all)")
        XCTAssertEqual(e.latest?.activeNames, ["↳ alpha 작업", "↳ Zeta 작업"])
        XCTAssertEqual(e.latest?.idleNames, ["부모"])
    }

    func testParentCountedSeparatelyFromItsSubagents() async throws {
        let (dir, projects) = (try makeTempDir(), try makeTempDir())
        defer { [dir, projects].forEach { try? FileManager.default.removeItem(at: $0) } }
        let p = try spawnSleeper(); defer { p.terminate() }
        let pid = Int(p.processIdentifier)
        try write(dir, pid: pid, status: "busy", name: "부모")
        try writeAgent(projects, parentPid: pid, id: "a", description: "하나")
        try writeAgent(projects, parentPid: pid, id: "b", description: "둘")
        let m = monitor(dir, projects)
        let (e, task) = collect(m)
        m.start(); defer { m.stop(); task.cancel() }
        let ok = await waitUntil { e.latest?.numbers == [3, 0, 0] }
        XCTAssertTrue(ok, "emitted: \(e.all)")
        XCTAssertEqual(e.latest?.activeNames, ["부모", "↳ 둘", "↳ 하나"])
    }

    func testFinishedSubagentExcluded() async throws {
        let (dir, projects) = (try makeTempDir(), try makeTempDir())
        defer { [dir, projects].forEach { try? FileManager.default.removeItem(at: $0) } }
        let p = try spawnSleeper(); defer { p.terminate() }
        let pid = Int(p.processIdentifier)
        try write(dir, pid: pid, status: "idle")
        try writeAgent(projects, parentPid: pid, id: "run", description: "실행중")
        try writeAgent(projects, parentPid: pid, id: "done", description: "끝남", finished: true)
        try writeAgent(projects, parentPid: pid, id: "false", description: "false 명시", finished: false)
        let m = monitor(dir, projects)
        let (e, task) = collect(m)
        m.start(); defer { m.stop(); task.cancel() }
        let ok = await waitUntil { e.latest?.numbers == [2, 0, 1] }
        XCTAssertTrue(ok, "emitted: \(e.all)")
        XCTAssertEqual(e.latest?.activeNames, ["↳ false 명시", "↳ 실행중"])
    }

    func testStaleSubagentExcludedByMtime() async throws {
        let (dir, projects) = (try makeTempDir(), try makeTempDir())
        defer { [dir, projects].forEach { try? FileManager.default.removeItem(at: $0) } }
        let p = try spawnSleeper(); defer { p.terminate() }
        let pid = Int(p.processIdentifier)
        let stale = SessionMonitor.subagentStaleThreshold
        try write(dir, pid: pid, status: "idle")
        try writeAgent(projects, parentPid: pid, id: "old", description: "오래됨", age: stale + 60)
        try writeAgent(projects, parentPid: pid, id: "oldmeta", description: "meta만 오래됨", age: stale + 60, withJsonl: false)
        try writeAgent(projects, parentPid: pid, id: "fresh", description: "최근", age: stale - 60)
        let m = monitor(dir, projects)
        let (e, task) = collect(m)
        m.start(); defer { m.stop(); task.cancel() }
        let ok = await waitUntil { e.latest?.numbers == [1, 0, 1] }
        XCTAssertTrue(ok, "emitted: \(e.all)")
        XCTAssertEqual(e.latest?.activeNames, ["↳ 최근"])
    }

    /// meta 는 오래됐어도 jsonl 이 최근에 갱신됐다면 실행 중이다.
    func testRecentJsonlKeepsOldMetaRunning() async throws {
        let (dir, projects) = (try makeTempDir(), try makeTempDir())
        defer { [dir, projects].forEach { try? FileManager.default.removeItem(at: $0) } }
        let p = try spawnSleeper(); defer { p.terminate() }
        let pid = Int(p.processIdentifier)
        try write(dir, pid: pid, status: "idle")
        let meta = try writeAgent(projects, parentPid: pid, id: "x", description: "장기 작업")
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-SessionMonitor.subagentStaleThreshold - 600)], ofItemAtPath: meta.path)
        let m = monitor(dir, projects)
        let (e, task) = collect(m)
        m.start(); defer { m.stop(); task.cancel() }
        let ok = await waitUntil { e.latest?.numbers == [1, 0, 1] }
        XCTAssertTrue(ok, "emitted: \(e.all)")
    }

    func testDeadParentSubagentsExcluded() async throws {
        let (dir, projects) = (try makeTempDir(), try makeTempDir())
        defer { [dir, projects].forEach { try? FileManager.default.removeItem(at: $0) } }
        let alive = try spawnSleeper(); defer { alive.terminate() }
        let alivePid = Int(alive.processIdentifier)
        let dead = try deadPid()
        try write(dir, pid: alivePid, status: "idle", name: "살아있음")
        try write(dir, pid: dead, status: "busy", name: "죽음")
        try writeAgent(projects, parentPid: alivePid, id: "a", description: "산 부모의 자식")
        try writeAgent(projects, parentPid: dead, id: "b", description: "죽은 부모의 자식")
        // 세션 파일이 아예 없는 sessionId 의 서브에이전트도 무시
        try writeAgent(projects, parentPid: 999_999, id: "c", description: "고아")
        let m = monitor(dir, projects)
        let (e, task) = collect(m)
        m.start(); defer { m.stop(); task.cancel() }
        let ok = await waitUntil { e.latest?.numbers == [1, 0, 1] }
        XCTAssertTrue(ok, "emitted: \(e.all)")
        XCTAssertEqual(e.latest?.activeNames, ["↳ 산 부모의 자식"])
    }

    func testEmptyOrMissingDescriptionFallsBack() async throws {
        let (dir, projects) = (try makeTempDir(), try makeTempDir())
        defer { [dir, projects].forEach { try? FileManager.default.removeItem(at: $0) } }
        let p = try spawnSleeper(); defer { p.terminate() }
        let pid = Int(p.processIdentifier)
        try write(dir, pid: pid, status: "idle")
        try writeAgent(projects, parentPid: pid, id: "a", description: "")
        try writeAgent(projects, parentPid: pid, id: "b", description: "  \n ")
        try writeAgent(projects, parentPid: pid, id: "c", description: nil)
        let m = monitor(dir, projects)
        let (e, task) = collect(m)
        m.start(); defer { m.stop(); task.cancel() }
        let ok = await waitUntil { e.latest?.numbers == [3, 0, 1] }
        XCTAssertTrue(ok, "emitted: \(e.all)")
        XCTAssertEqual(e.latest?.activeSessions.map(\.placeholder), Array(repeating: .subagent, count: 3))
        XCTAssertEqual(e.latest?.activeNames, Array(repeating: "", count: 3))
    }

    func testNestedSubagentIncluded() async throws {
        let (dir, projects) = (try makeTempDir(), try makeTempDir())
        defer { [dir, projects].forEach { try? FileManager.default.removeItem(at: $0) } }
        let p = try spawnSleeper(); defer { p.terminate() }
        let pid = Int(p.processIdentifier)
        try write(dir, pid: pid, status: "busy", name: "부모")
        try writeAgent(projects, parentPid: pid, id: "a", description: "1단계", depth: 1)
        try writeAgent(projects, parentPid: pid, id: "b", description: "2단계", depth: 2)
        let m = monitor(dir, projects)
        let (e, task) = collect(m)
        m.start(); defer { m.stop(); task.cancel() }
        let ok = await waitUntil { e.latest?.numbers == [3, 0, 0] }
        XCTAssertTrue(ok, "emitted: \(e.all)")
        XCTAssertEqual(e.latest?.activeNames, ["부모", "↳ 1단계", "↳ 2단계"])
    }

    func testFindsSessionAcrossAnyProjectDirectory() async throws {
        let (dir, projects) = (try makeTempDir(), try makeTempDir())
        defer { [dir, projects].forEach { try? FileManager.default.removeItem(at: $0) } }
        let p = try spawnSleeper(); defer { p.terminate() }
        let pid = Int(p.processIdentifier)
        try write(dir, pid: pid, status: "idle")
        try writeAgent(projects, parentPid: pid, id: "a", description: "엉뚱한 인코딩 디렉터리", project: "아무-이름-1")
        try FileManager.default.createDirectory(at: projects.appendingPathComponent("빈-프로젝트"), withIntermediateDirectories: true)
        let m = monitor(dir, projects)
        let (e, task) = collect(m)
        m.start(); defer { m.stop(); task.cancel() }
        let ok = await waitUntil { e.latest?.numbers == [1, 0, 1] }
        XCTAssertTrue(ok, "emitted: \(e.all)")
    }

    func testMissingProjectsDirectoryIsHarmless() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = try spawnSleeper(); defer { p.terminate() }
        try write(dir, pid: Int(p.processIdentifier), status: "busy")
        let m = monitor(dir, FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString)"))
        let (e, task) = collect(m)
        m.start(); defer { m.stop(); task.cancel() }
        let ok = await waitUntil { e.latest?.numbers == [1, 0, 0] }
        XCTAssertTrue(ok, "emitted: \(e.all)")
    }

    /// 서브에이전트 meta 생성 -> 종료(finished) -> 삭제가 projects 디렉터리 감시만으로 반영된다(주기 재스캔 60초 -> 사실상 비활성).
    func testEmitsOnSubagentMetaCreateAndFinish() async throws {
        let (dir, projects) = (try makeTempDir(), try makeTempDir())
        defer { [dir, projects].forEach { try? FileManager.default.removeItem(at: $0) } }
        let p = try spawnSleeper(); defer { p.terminate() }
        let pid = Int(p.processIdentifier)
        try write(dir, pid: pid, status: "idle", name: "부모")
        let m = monitor(dir, projects)
        let (e, task) = collect(m)
        m.start(); defer { m.stop(); task.cancel() }
        var ok = await waitUntil { e.latest?.numbers == [0, 0, 1] }
        XCTAssertTrue(ok, "initial: \(e.all)")

        try writeAgent(projects, parentPid: pid, id: "a", description: "첫째")
        ok = await waitUntil { e.latest?.numbers == [1, 0, 1] }
        XCTAssertTrue(ok, "spawn: \(e.all)")
        XCTAssertEqual(e.latest?.activeNames, ["↳ 첫째"])

        try writeAgent(projects, parentPid: pid, id: "b", description: "둘째")
        ok = await waitUntil { e.latest?.numbers == [2, 0, 1] }
        XCTAssertTrue(ok, "second spawn: \(e.all)")

        try writeAgent(projects, parentPid: pid, id: "a", description: "첫째", finished: true)
        ok = await waitUntil { e.latest?.numbers == [1, 0, 1] }
        XCTAssertTrue(ok, "finish: \(e.all)")
        XCTAssertEqual(e.latest?.activeNames, ["↳ 둘째"])

        // 결과가 같은 jsonl append 는 emit 하지 않는다
        let before = e.all.count
        let jsonl = projects.appendingPathComponent("-proj/s-\(pid)/subagents/agent-b.jsonl")
        let h = try FileHandle(forWritingTo: jsonl)
        try h.seekToEnd(); try h.write(contentsOf: Data("{}\n".utf8)); try h.close()
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(e.all.count, before, "unchanged counts must not re-emit: \(e.all)")
    }

    /// 파일 변경 없이 시간만 지나 stale 이 되는 경우는 주기 재스캔이 잡는다.
    func testPeriodicRescanDropsStaleSubagent() async throws {
        let (dir, projects) = (try makeTempDir(), try makeTempDir())
        defer { [dir, projects].forEach { try? FileManager.default.removeItem(at: $0) } }
        let p = try spawnSleeper(); defer { p.terminate() }
        let pid = Int(p.processIdentifier)
        try write(dir, pid: pid, status: "idle")
        // 임계값 직전(2초 남음)으로 설정
        try writeAgent(projects, parentPid: pid, id: "a", description: "곧 만료", age: SessionMonitor.subagentStaleThreshold - 2)
        let m = monitor(dir, projects, rescan: 0.5)
        let (e, task) = collect(m)
        m.start(); defer { m.stop(); task.cancel() }
        var ok = await waitUntil { e.latest?.numbers == [1, 0, 1] }
        XCTAssertTrue(ok, "initial: \(e.all)")
        ok = await waitUntil(timeout: 6) { e.latest?.numbers == [0, 0, 1] }
        XCTAssertTrue(ok, "after stale: \(e.all)")
    }

    func testSubagentNameRules() {
        XCTAssertEqual(SessionMonitor.subagentName(description: " 작업 "), "↳ 작업")
        XCTAssertNil(SessionMonitor.subagentName(description: ""))
        XCTAssertNil(SessionMonitor.subagentName(description: nil))
    }
}

// MARK: - 구조화 세션 정보(SessionRef)

final class SessionRefTests: XCTestCase {
    private func monitor(_ dir: URL, _ projects: URL? = nil) -> SessionMonitor {
        SessionMonitor(directory: dir, projectsDirectory: projects ?? noProjectsDir(), statusMapping: .default, debounce: 0.1, rescanInterval: 60)
    }

    func testRefsCarryPidAndEntrypointAndSubagentParent() async throws {
        let (dir, projects) = (try makeTempDir(), try makeTempDir())
        defer { [dir, projects].forEach { try? FileManager.default.removeItem(at: $0) } }
        let procs = try (0..<3).map { _ in try spawnSleeper() }
        defer { procs.forEach { $0.terminate() } }
        let p = procs.map { Int($0.processIdentifier) }
        try write(dir, pid: p[0], status: "busy", name: "데스크탑", entrypoint: "claude-desktop")
        try write(dir, pid: p[1], status: "waiting", name: "터미널", entrypoint: "cli")
        try write(dir, pid: p[2], status: "idle", name: "구버전")                       // entrypoint 없음
        let sub = projects.appendingPathComponent("-proj/s-\(p[0])/subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["description": "조사"]).write(to: sub.appendingPathComponent("agent-a.meta.json"))
        try Data("{}\n".utf8).write(to: sub.appendingPathComponent("agent-a.jsonl"))

        let m = monitor(dir, projects)
        let e = Emissions()
        let stream = m.countsStream()
        let task = Task { for await c in stream { e.append(c) } }
        m.start(); defer { m.stop(); task.cancel() }
        let ok = await waitUntil { e.latest?.numbers == [2, 1, 1] }
        XCTAssertTrue(ok, "emitted: \(e.all)")
        let latest = try XCTUnwrap(e.latest)
        XCTAssertEqual(latest.activeSessions, [
            SessionRef(name: "데스크탑", pid: Int32(p[0]), entrypoint: "claude-desktop"),
            SessionRef(name: "↳ 조사", pid: nil, entrypoint: "claude-desktop", isSubagent: true, parentPid: Int32(p[0])),
        ])
        XCTAssertEqual(latest.waitingSessions, [SessionRef(name: "터미널", pid: Int32(p[1]), entrypoint: "cli")])
        XCTAssertEqual(latest.idleSessions, [SessionRef(name: "구버전", pid: Int32(p[2]), entrypoint: nil)])
        XCTAssertEqual(latest.activeNames, ["데스크탑", "↳ 조사"])
    }
}

// MARK: - 부모 사슬 탐색

final class ProcessAncestryTests: XCTestCase {
    /// 가짜 프로세스 트리: pid -> ppid
    private func walk(
        _ pid: Int32, tree: [Int32: Int32], apps: Set<Int32>, maxDepth: Int = ProcessAncestry.maxDepth
    ) -> Int32? {
        ProcessAncestry.firstAncestor(of: pid, maxDepth: maxDepth, parentOf: { tree[$0] }, matches: { apps.contains($0) })
    }

    func testDirectParentApp() {
        XCTAssertEqual(walk(300, tree: [300: 200, 200: 1], apps: [200]), 200)
    }

    func testSelfMatchesFirst() {
        XCTAssertEqual(walk(300, tree: [300: 200, 200: 1], apps: [300, 200]), 300)
    }

    func testMultipleLevelsPicksNearestApp() {
        // claude(500) -> zsh(400) -> login(300) -> Terminal(200) -> launchd(1);  상위의 다른 앱(150)보다 가까운 쪽
        let tree: [Int32: Int32] = [500: 400, 400: 300, 300: 200, 200: 150, 150: 1]
        XCTAssertEqual(walk(500, tree: tree, apps: [200, 150]), 200)
    }

    func testNoAppReturnsNilAndStopsAtLaunchd() {
        var asked: [Int32] = []
        let r = ProcessAncestry.firstAncestor(of: 500, parentOf: { asked.append($0); return [500: 400, 400: 1, 1: 0][$0] }, matches: { _ in false })
        XCTAssertNil(r)
        XCTAssertEqual(asked, [500, 400]) // pid 1 에서 멈춘다(부모 조회 안 함)
    }

    func testLaunchdIsNeverMatched() {
        XCTAssertNil(walk(400, tree: [400: 1], apps: [1]))
    }

    func testCycleTerminates() {
        var calls = 0
        let r = ProcessAncestry.firstAncestor(of: 10, parentOf: { calls += 1; return [10: 20, 20: 30, 30: 10][$0] }, matches: { _ in false })
        XCTAssertNil(r)
        XCTAssertEqual(calls, 3)
        XCTAssertNil(walk(7, tree: [7: 7], apps: []))
    }

    func testDepthCap() {
        // 100 -> 99 -> ... -> 2, 앱은 맨 끝(2)
        let tree = Dictionary(uniqueKeysWithValues: (3...100).map { (Int32($0), Int32($0 - 1)) })
        XCTAssertEqual(walk(100, tree: tree, apps: [2], maxDepth: 200), 2)
        XCTAssertNil(walk(100, tree: tree, apps: [2])) // 기본 상한(32단계) 안에서는 도달 못함
        XCTAssertEqual(walk(100, tree: tree, apps: [100 - 31]), 69) // 32번째 단계까지는 도달
        XCTAssertNil(walk(100, tree: tree, apps: [100 - 32]))
    }

    func testParentLookupFailureReturnsNil() {
        XCTAssertNil(walk(300, tree: [:], apps: [200]))
    }

    func testRealParentPidMatchesGetppid() {
        XCTAssertEqual(ProcessAncestry.parentPid(of: getpid()), getppid())
        XCTAssertNil(ProcessAncestry.parentPid(of: 0))
        XCTAssertNil(ProcessAncestry.parentPid(of: Int32.max))
    }
}
