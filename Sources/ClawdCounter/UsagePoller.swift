import CoreModels
import Foundation
import UsageKit

/// 사용량 폴링. 성공 시 기본 간격, 실패 시 지수 백오프(최대 10분, `Retry-After` 반영).
/// 메인 액터에서만 사용한다. `stop()` 이후 늦게 도착한 결과는 generation 으로 버린다.
@MainActor
final class UsagePoller {
    static let maxBackoff: TimeInterval = 600
    /// 메뉴를 열 때의 즉시 갱신 최소 간격(너무 잦은 호출 방지).
    static let minManualGap: TimeInterval = 15

    private let client: any UsageProviding
    private let interval: () -> TimeInterval
    private let onSuccess: (UsageSnapshot) -> Void
    private let onFailure: () -> Void

    private var task: Task<Void, Never>?
    private var generation = 0
    private var failures = 0
    private var isFetching = false
    private var lastAttempt: Date?

    var isRunning: Bool { task != nil }

    init(
        client: any UsageProviding,
        interval: @escaping () -> TimeInterval,
        onSuccess: @escaping (UsageSnapshot) -> Void,
        onFailure: @escaping () -> Void
    ) {
        self.client = client
        self.interval = interval
        self.onSuccess = onSuccess
        self.onFailure = onFailure
    }

    /// 폴링 시작(이미 돌고 있으면 재시작). 백오프 상태는 초기화한다.
    func start(immediate: Bool = true) {
        failures = 0
        launch(initialDelay: immediate ? 0 : interval())
    }

    func stop() {
        generation += 1
        task?.cancel()
        task = nil
        isFetching = false
    }

    /// 갱신 주기 설정이 바뀐 경우: 대기 중이면 새 주기로 다시 대기한다(진행 중인 요청은 건드리지 않음).
    func reschedule() {
        guard task != nil, !isFetching else { return }
        launch(initialDelay: nextDelay(retryAfter: nil))
    }

    /// 메뉴 열기 등 즉시 갱신 요청. 백오프 중이거나 직전 시도가 너무 최근이면 무시한다.
    func refreshNow() {
        guard task != nil, !isFetching, failures == 0 else { return }
        if let last = lastAttempt, Date().timeIntervalSince(last) < Self.minManualGap { return }
        launch(initialDelay: 0)
    }

    // MARK: - 내부

    private func launch(initialDelay: TimeInterval) {
        generation += 1
        let gen = generation
        task?.cancel()
        isFetching = false
        task = Task { [weak self] in
            var delay = initialDelay
            while true {
                if delay > 0 {
                    do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                }
                guard let self, self.generation == gen else { return }
                guard let next = await self.tick(gen) else { return }
                delay = next
            }
        }
    }

    /// 한 번 조회하고 다음 대기 시간을 돌려준다. 도중에 중지/교체되었으면 nil.
    private func tick(_ gen: Int) async -> TimeInterval? {
        isFetching = true
        lastAttempt = Date()
        var retryAfter: TimeInterval?
        do {
            let snapshot = try await client.fetch()
            guard gen == generation else { return nil }
            failures = 0
            isFetching = false
            onSuccess(snapshot)
        } catch is CancellationError {
            return nil
        } catch {
            guard gen == generation else { return nil }
            failures += 1
            isFetching = false
            retryAfter = (error as? UsageError)?.retryAfter
            onFailure()
        }
        return nextDelay(retryAfter: retryAfter)
    }

    private func nextDelay(retryAfter: TimeInterval?) -> TimeInterval {
        let base = interval()
        guard failures > 0 else { return base }
        let exponent = Double(min(failures, 10))
        let backoff = min(Self.maxBackoff, base * pow(2, exponent))
        return min(Self.maxBackoff, max(backoff, retryAfter ?? 0))
    }
}
