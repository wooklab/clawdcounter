import Foundation

public struct LimitWindow: Equatable, Sendable {
    public var usedPercent: Double // 0-100
    public var resetsAt: Date?
    public init(usedPercent: Double, resetsAt: Date? = nil) {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }
}

public struct CreditUsage: Equatable, Sendable {
    public var used: Double
    public var total: Double? // nil = 한도 없음/알 수 없음
    public var unit: String?
    public var isEnabled: Bool // 추가 사용(크레딧) 활성 여부
    public init(used: Double, total: Double? = nil, unit: String? = nil, isEnabled: Bool = true) {
        self.used = used
        self.total = total
        self.unit = unit
        self.isEnabled = isEnabled
    }
}

public struct ResetTicketStatus: Equatable, Sendable {
    public var remaining: Int
    public var total: Int?
    public init(remaining: Int, total: Int? = nil) {
        self.remaining = remaining
        self.total = total
    }
}

public struct UsageSnapshot: Equatable, Sendable {
    public var fiveHour: LimitWindow?
    public var weekly: LimitWindow?
    public var fable: LimitWindow?
    public var credit: CreditUsage?
    public var resetTickets: ResetTicketStatus?
    public var fetchedAt: Date
    public init(
        fiveHour: LimitWindow? = nil,
        weekly: LimitWindow? = nil,
        fable: LimitWindow? = nil,
        credit: CreditUsage? = nil,
        resetTickets: ResetTicketStatus? = nil,
        fetchedAt: Date
    ) {
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.fable = fable
        self.credit = credit
        self.resetTickets = resetTickets
        self.fetchedAt = fetchedAt
    }
}

/// 세션명 대체 표시 종류. 실제 문자열은 UI 계층이 `L10n` 으로 그린다.
public enum SessionNamePlaceholder: Equatable, Sendable {
    /// `name`·`cwd` 모두 없음("이름 없음").
    case unnamed
    /// description 이 빈 서브에이전트("↳ 서브에이전트").
    case subagent
}

/// 드롭다운에 나열되는 세션 한 건의 구조화 정보.
public struct SessionRef: Equatable, Sendable {
    public var name: String
    public var pid: Int32?
    public var entrypoint: String?
    public var isSubagent: Bool
    /// 서브에이전트일 때 부모 세션의 pid.
    public var parentPid: Int32?
    /// 이름을 정할 수 없을 때의 대체 표시명 종류. nil 이 아니면 `name` 은 비어 있고, UI 가 언어별 문자열로 그린다.
    public var placeholder: SessionNamePlaceholder?
    public init(
        name: String, pid: Int32? = nil, entrypoint: String? = nil, isSubagent: Bool = false, parentPid: Int32? = nil,
        placeholder: SessionNamePlaceholder? = nil
    ) {
        self.name = name
        self.pid = pid
        self.entrypoint = entrypoint
        self.isSubagent = isSubagent
        self.parentPid = parentPid
        self.placeholder = placeholder
    }

    /// 앞으로 가져올 앱을 찾는 출발 pid: 서브에이전트는 부모 세션, 그 밖에는 자기 자신.
    public var focusPid: Int32? { isSubagent ? parentPid : pid }
}

public struct SessionCounts: Equatable, Sendable {
    public var active: Int
    public var waiting: Int
    public var idle: Int
    /// 상태별 세션(정렬된 순서). 개수 필드와 별개로 보관하며, 모니터는 항상 `sessions.count == 개수`로 채운다.
    public var activeSessions: [SessionRef]
    public var waitingSessions: [SessionRef]
    public var idleSessions: [SessionRef]

    public var activeNames: [String] { activeSessions.map(\.name) }
    public var waitingNames: [String] { waitingSessions.map(\.name) }
    public var idleNames: [String] { idleSessions.map(\.name) }

    /// 구조화 정보를 직접 넘기는 초기화. (이름만 넘기는 초기화와 모호해지지 않도록 세션 배열은 필수.)
    public init(
        active: Int, waiting: Int, idle: Int,
        activeSessions: [SessionRef], waitingSessions: [SessionRef], idleSessions: [SessionRef]
    ) {
        self.active = active
        self.waiting = waiting
        self.idle = idle
        self.activeSessions = activeSessions
        self.waitingSessions = waitingSessions
        self.idleSessions = idleSessions
    }

    /// 이름만 넘기는 호환 초기화: 각 이름은 pid 없는 `SessionRef` 가 된다.
    public init(
        active: Int, waiting: Int, idle: Int,
        activeNames: [String] = [], waitingNames: [String] = [], idleNames: [String] = []
    ) {
        self.init(
            active: active, waiting: waiting, idle: idle,
            activeSessions: activeNames.map { SessionRef(name: $0) },
            waitingSessions: waitingNames.map { SessionRef(name: $0) },
            idleSessions: idleNames.map { SessionRef(name: $0) })
    }
}

public enum AuthState: Equatable, Sendable { case signedOut, signingIn, signedIn, expired }

public protocol TokenProviding: Sendable {
    func validAccessToken() async throws -> String // 필요 시 refresh
}

public protocol AuthManaging: TokenProviding {
    var state: AuthState { get async }
    func login() async throws
    func logout() async
    func stateStream() -> AsyncStream<AuthState>
}

public protocol UsageProviding: Sendable {
    func fetch() async throws -> UsageSnapshot
}

public protocol SessionMonitoring: Sendable {
    func countsStream() -> AsyncStream<SessionCounts>
}

/// 멀티캐스트 헬퍼. `stream()` 호출마다 독립 AsyncStream을 반환하고 `send(_:)`가 모든 구독자에게 전달한다.
/// 상태 스트림 용도: 구독자별 버퍼는 최신 1개만 유지하므로 느린 소비자는 중간 값을 건너뛴다.
public final class Broadcaster<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<T>.Continuation] = [:]
    private var latest: T?
    private let replayLatest: Bool

    /// - Parameter replayLatest: true면 새 구독자에게 마지막으로 보낸 값을 즉시 전달한다.
    public init(replayLatest: Bool = false) {
        self.replayLatest = replayLatest
    }

    public func stream() -> AsyncStream<T> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<T>.makeStream(bufferingPolicy: .bufferingNewest(1))
        lock.lock()
        continuations[id] = continuation
        let replay = replayLatest ? latest : nil
        if let replay { continuation.yield(replay) }
        lock.unlock()
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.continuations[id] = nil
            self.lock.unlock()
        }
        return stream
    }

    public func send(_ value: T) {
        lock.lock()
        if replayLatest { latest = value }
        let targets = Array(continuations.values)
        for c in targets { c.yield(value) }
        lock.unlock()
    }

    /// 모든 구독자 스트림을 종료한다.
    public func finish() {
        lock.lock()
        let targets = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()
        for c in targets { c.finish() }
    }
}
