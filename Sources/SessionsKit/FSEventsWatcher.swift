import Foundation
import CoreServices

/// 디렉터리 하위 변경(파일 내용 수정 포함)을 FSEvents로 감시한다.
/// 모든 메서드는 소유자(SessionMonitor)의 직렬 큐에서만 호출한다.
final class FSEventsWatcher: @unchecked Sendable {
    private let path: String
    private let queue: DispatchQueue
    private let onChange: @Sendable () -> Void
    private var stream: FSEventStreamRef?

    init(path: String, queue: DispatchQueue, onChange: @escaping @Sendable () -> Void) {
        self.path = path
        self.queue = queue
        self.onChange = onChange
    }

    func start() {
        guard stream == nil else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
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
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
