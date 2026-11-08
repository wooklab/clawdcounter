import Foundation
import CoreModels
import os

/// `~/.claude/sessions/<pid>.json`을 읽어 세션 수를 활성/응답대기/비활성으로 분류해 내보낸다.
/// 살아있는 세션의 실행 중 서브에이전트(`~/.claude/projects/*/<sessionId>/subagents/agent-*.meta.json` 중
/// `finished` 가 true 가 아니고 최근 갱신된 것)는 `active` 에 1개씩 더하고 `activeNames` 에 `↳ 설명` 으로 덧붙인다.
/// 가변 상태는 모두 직렬 큐 `queue`에서만 접근한다.
public final class SessionMonitor: SessionMonitoring, @unchecked Sendable {
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions", isDirectory: true)
    }

    /// 서브에이전트 파일(jsonl/meta)의 mtime 이 이보다 오래되면 크래시 등으로 `finished` 가 안 붙은 잔존물로 보고 제외한다(초).
    public static let subagentStaleThreshold: TimeInterval = 600
    /// description 이 비었을 때 쓰는 서브에이전트 표시명 본문.
    static let subagentFallbackName = "서브에이전트"
    static let subagentPrefix = "↳ "

    public static var defaultProjectsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true)
    }

    private let directory: URL
    private let projectsDirectory: URL
    private let mapping: StatusMapping
    private let debounce: TimeInterval
    private let rescanInterval: TimeInterval
    private let queue = DispatchQueue(label: "clawdcounter.sessions-monitor")
    private let broadcaster = Broadcaster<SessionCounts>(replayLatest: true)
    private let log = Logger(subsystem: "clawdcounter", category: "SessionMonitor")

    // queue 전용 상태
    private var started = false
    private var watcher: FSEventsWatcher?
    private var projectsWatcher: FSEventsWatcher?
    private var rescanTimer: DispatchSourceTimer?
    private var debounceTimer: DispatchSourceTimer?
    private var lastCounts: SessionCounts?
    private var loggedUnknownStatuses = Set<String>()

    public convenience init(
        directory: URL = SessionMonitor.defaultDirectory,
        projectsDirectory: URL = SessionMonitor.defaultProjectsDirectory,
        statusMapping: StatusMapping = .default
    ) {
        self.init(directory: directory, projectsDirectory: projectsDirectory, statusMapping: statusMapping, debounce: 2, rescanInterval: 15)
    }

    init(
        directory: URL, projectsDirectory: URL = SessionMonitor.defaultProjectsDirectory,
        statusMapping: StatusMapping, debounce: TimeInterval, rescanInterval: TimeInterval
    ) {
        self.directory = directory
        self.projectsDirectory = projectsDirectory
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

            let projectsWatcher = FSEventsWatcher(path: projectsDirectory.path, queue: queue) { [weak self] in
                self?.scheduleDebouncedScan()
            }
            projectsWatcher.start()
            self.projectsWatcher = projectsWatcher

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
            projectsWatcher?.stop()
            projectsWatcher = nil
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
        var active: [SessionRef] = []
        var waiting: [SessionRef] = []
        var idle: [SessionRef] = []
        var parents: [String: (pid: Int, entrypoint: String?)] = [:]
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for file in files {
            guard let record = readRecord(named: file) else { continue }
            let pid = record.pid
            guard ProcessProbe.isAlive(pid) else { continue }
            if let procStart = record.procStart, ProcessProbe.procStartMatches(procStart, pid: pid) == false { continue }

            let (kind, known) = mapping.classify(record.status)
            if !known { logUnknown(record.status) }
            if let sid = record.sessionId, parents[sid].map({ pid < $0.pid }) ?? true { parents[sid] = (pid, record.entrypoint) }
            let ref = SessionRef(
                name: Self.displayName(name: record.name, cwd: record.cwd),
                pid: Int32(truncatingIfNeeded: pid), entrypoint: record.entrypoint)
            switch kind {
            case .active: active.append(ref)
            case .waiting: waiting.append(ref)
            case .idle: idle.append(ref)
            }
        }
        func sorted(_ refs: [SessionRef]) -> [SessionRef] {
            refs.sorted {
                let order = $0.name.compare($1.name, options: [.caseInsensitive, .numeric])
                return order == .orderedSame ? ($0.pid ?? 0) < ($1.pid ?? 0) : order == .orderedAscending
            }
        }
        let subagents = runningSubagents(parents: parents, now: Date())
        let activeAll = sorted(active) + subagents
        return SessionCounts(
            active: activeAll.count, waiting: waiting.count, idle: idle.count,
            activeSessions: activeAll, waitingSessions: sorted(waiting), idleSessions: sorted(idle))
    }

    /// 살아있는 세션들의 실행 중 서브에이전트를 `↳ 설명` 이름순으로 반환한다(부모 pid·entrypoint 를 붙인다).
    /// 살아있는 sessionId 마다 `projects/*/<sessionId>/subagents` 만 연다. jsonl 은 읽지 않고 stat 만 한다.
    private func runningSubagents(parents: [String: (pid: Int, entrypoint: String?)], now: Date) -> [SessionRef] {
        guard !parents.isEmpty else { return [] }
        let fm = FileManager.default
        let projectDirs = (try? fm.contentsOfDirectory(
            at: projectsDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        guard !projectDirs.isEmpty else { return [] }

        func mtime(_ url: URL) -> Date? {
            (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        }

        var found: [(ref: SessionRef, key: String)] = []
        var seen = Set<String>()
        for sid in parents.keys.sorted() {
            // sessionId 는 파일 내용이므로 경로 요소로 안전한 값만 허용한다.
            guard !sid.isEmpty, sid != ".", sid != "..", !sid.contains("/"), !sid.contains("\0"), let parent = parents[sid] else { continue }
            for project in projectDirs {
                let dir = project.appendingPathComponent(sid, isDirectory: true).appendingPathComponent("subagents", isDirectory: true)
                guard let entries = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
                for file in entries where file.hasPrefix("agent-") && file.hasSuffix(".meta.json") {
                    let meta = dir.appendingPathComponent(file)
                    guard seen.insert(meta.path).inserted else { continue }
                    let id = String(file.dropFirst("agent-".count).dropLast(".meta.json".count))
                    let jsonl = dir.appendingPathComponent("agent-\(id).jsonl")
                    guard let latest = [mtime(meta), mtime(jsonl)].compactMap({ $0 }).max(),
                          now.timeIntervalSince(latest) <= Self.subagentStaleThreshold
                    else { continue }
                    guard let data = try? Data(contentsOf: meta), data.count <= 262_144,
                          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          (object["finished"] as? Bool) != true
                    else { continue }
                    let ref = SessionRef(
                        name: Self.subagentName(description: object["description"] as? String),
                        pid: nil, entrypoint: parent.entrypoint, isSubagent: true,
                        parentPid: Int32(truncatingIfNeeded: parent.pid))
                    found.append((ref, meta.path))
                }
            }
        }
        return found.sorted {
            let order = $0.ref.name.compare($1.ref.name, options: [.caseInsensitive, .numeric])
            return order == .orderedSame ? $0.key < $1.key : order == .orderedAscending
        }.map(\.ref)
    }

    /// `↳ <description>`; description 이 비면 `↳ 서브에이전트`.
    static func subagentName(description: String?) -> String {
        let text = description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return subagentPrefix + (text.isEmpty ? subagentFallbackName : text)
    }

    /// 세션명: `name`(공백 제외 비어 있지 않을 때) -> `cwd` 의 마지막 경로 요소 -> "이름 없음".
    static func displayName(name: String?, cwd: String?) -> String {
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        if let cwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines), !cwd.isEmpty {
            let last = (cwd as NSString).lastPathComponent
            if !last.isEmpty, last != "/" { return last }
        }
        return "이름 없음"
    }

    /// `<pid>.json`만 허용(`<pid>.<hash>.key` 등 무시). 읽기/파싱 실패(부분 쓰기 포함)는 nil.
    private func readRecord(named name: String) -> (pid: Int, status: String?, procStart: String?, name: String?, cwd: String?, sessionId: String?, entrypoint: String?)? {
        guard name.hasSuffix(".json"),
              let pid = Int(name.dropLast(".json".count)), pid > 0, String(pid) == name.dropLast(".json".count)
        else { return nil }
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
              data.count <= 262_144,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return (pid, object["status"] as? String, object["procStart"] as? String,
                object["name"] as? String, object["cwd"] as? String, object["sessionId"] as? String,
                object["entrypoint"] as? String)
    }

    private func logUnknown(_ status: String?) {
        let key = status ?? "<missing>"
        guard loggedUnknownStatuses.insert(key).inserted else { return }
        log.warning("unknown session status '\(key, privacy: .public)'; treating as idle")
    }
}
