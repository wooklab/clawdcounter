import Foundation
import CoreModels
import os

/// `~/.claude/sessions/<pid>.json`을 읽어 세션 수를 활성/응답대기/비활성으로 분류해 내보낸다.
/// 가변 상태는 모두 직렬 큐 `queue`에서만 접근한다.
public final class SessionMonitor: SessionMonitoring, @unchecked Sendable {
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions", isDirectory: true)
    }

    private let directory: URL
    private let mapping: StatusMapping
    private let debounce: TimeInterval
    private let rescanInterval: TimeInterval
    private let queue = DispatchQueue(label: "clawdcounter.sessions-monitor")
    private let broadcaster = Broadcaster<SessionCounts>(replayLatest: true)
    private let log = Logger(subsystem: "clawdcounter", category: "SessionMonitor")

    // queue 전용 상태
    private var started = false
    private var watcher: FSEventsWatcher?
    private var rescanTimer: DispatchSourceTimer?
    private var debounceTimer: DispatchSourceTimer?
    private var lastCounts: SessionCounts?
    private var loggedUnknownStatuses = Set<String>()

    public convenience init(directory: URL = SessionMonitor.defaultDirectory, statusMapping: StatusMapping = .default) {
        self.init(directory: directory, statusMapping: statusMapping, debounce: 2, rescanInterval: 15)
    }

    init(directory: URL, statusMapping: StatusMapping, debounce: TimeInterval, rescanInterval: TimeInterval) {
        self.directory = directory
        self.mapping = statusMapping
        self.debounce = debounce
        self.rescanInterval = rescanInterval
    }

    public func countsStream() -> AsyncStream<SessionCounts> {
        broadcaster.stream()
    }

    /// 감시 시작 + 즉시 1회 스캔(반환 시점에 첫 값이 emit되어 있다). 중복 호출은 무시.
    public func start() {
        queue.sync {
            guard !started else { return }
            started = true

            let watcher = FSEventsWatcher(path: directory.path, queue: queue) { [weak self] in
                self?.scheduleDebouncedScan()
            }
            watcher.start()
            self.watcher = watcher

            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + rescanInterval, repeating: rescanInterval)
            timer.setEventHandler { [weak self] in self?.scan() }
            timer.resume()
            rescanTimer = timer

            scan()
        }
    }

    public func stop() {
        queue.sync {
            guard started else { return }
            started = false
            watcher?.stop()
            watcher = nil
            rescanTimer?.cancel()
            rescanTimer = nil
            debounceTimer?.cancel()
            debounceTimer = nil
        }
    }

    // MARK: - queue 내부

    /// 이벤트 폭주 시에도 최대 `debounce` 이후에 1회 스캔한다(기아 방지).
    private func scheduleDebouncedScan() {
        guard started, debounceTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + debounce)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.debounceTimer?.cancel()
            self.debounceTimer = nil
            self.scan()
        }
        timer.resume()
        debounceTimer = timer
    }

    private func scan() {
        guard started else { return }
        let counts = computeCounts()
        if counts != lastCounts {
            lastCounts = counts
            broadcaster.send(counts)
        }
    }

    private func computeCounts() -> SessionCounts {
        var counts = SessionCounts(active: 0, waiting: 0, idle: 0)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names {
            guard let (pid, status, procStart) = readRecord(named: name) else { continue }
            guard ProcessProbe.isAlive(pid) else { continue }
            if let procStart, ProcessProbe.procStartMatches(procStart, pid: pid) == false { continue }

            let (kind, known) = mapping.classify(status)
            if !known { logUnknown(status) }
            switch kind {
            case .active: counts.active += 1
            case .waiting: counts.waiting += 1
            case .idle: counts.idle += 1
            }
        }
        return counts
    }

    /// `<pid>.json`만 허용(`<pid>.<hash>.key` 등 무시). 읽기/파싱 실패(부분 쓰기 포함)는 nil.
    private func readRecord(named name: String) -> (pid: Int, status: String?, procStart: String?)? {
        guard name.hasSuffix(".json"),
              let pid = Int(name.dropLast(".json".count)), pid > 0, String(pid) == name.dropLast(".json".count)
        else { return nil }
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
              data.count <= 262_144,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return (pid, object["status"] as? String, object["procStart"] as? String)
    }

    private func logUnknown(_ status: String?) {
        let key = status ?? "<missing>"
        guard loggedUnknownStatuses.insert(key).inserted else { return }
        log.warning("unknown session status '\(key, privacy: .public)'; treating as idle")
    }
}
