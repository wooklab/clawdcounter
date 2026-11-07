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
    public var total: Double
    public var unit: String?
    public init(used: Double, total: Double, unit: String? = nil) {
        self.used = used
        self.total = total
        self.unit = unit
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

public struct SessionCounts: Equatable, Sendable {
    public var active: Int
    public var waiting: Int
    public var idle: Int
    public init(active: Int, waiting: Int, idle: Int) {
        self.active = active
        self.waiting = waiting
        self.idle = idle
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
