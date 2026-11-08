import Foundation
import CoreServices

/// FSEventStream 콜백 context. 스트림이 retain/release 콜백으로 수명을 소유하므로
/// watcher가 먼저 해제돼도 콜백은 watcher 대신 이 객체만 접근한다(use-after-free 방지).
private final class CallbackBox: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private let onChange: @Sendable () -> Void

    init(onChange: @escaping @Sendable () -> Void) { self.onChange = onChange }

    func cancel() { lock.lock(); cancelled = true; lock.unlock() }

    func fire() {
        lock.lock()
        let dead = cancelled
        lock.unlock()
        if !dead { onChange() } // 락 밖에서 호출: onChange가 소유자 해제로 이어져도 데드락 없음
    }
}

/// 디렉터리 하위 변경(파일 내용 수정 포함)을 FSEvents로 감시한다.
/// 모든 메서드는 소유자(SessionMonitor)의 직렬 큐에서만 호출한다(deinit은 어느 스레드든 안전).
final class FSEventsWatcher: @unchecked Sendable {
    private let path: String
    private let queue: DispatchQueue
    private let onChange: @Sendable () -> Void
    private var box: CallbackBox?
    private var stream: FSEventStreamRef?

    init(path: String, queue: DispatchQueue, onChange: @escaping @Sendable () -> Void) {
        self.path = path
        self.queue = queue
        self.onChange = onChange
    }

    func start() {
        guard stream == nil else { return }
        let box = CallbackBox(onChange: onChange)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(box).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<CallbackBox>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<CallbackBox>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue().fire()
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.1,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
        self.box = box
    }

    func stop() {
        box?.cancel()
        box = nil
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
