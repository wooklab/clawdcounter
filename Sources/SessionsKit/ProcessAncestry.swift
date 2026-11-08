import Foundation
import Darwin

/// 프로세스 부모 사슬 탐색. 부모 조회와 판정을 주입할 수 있어 가짜 프로세스 트리로 테스트한다.
public enum ProcessAncestry {
    /// 사슬 탐색 상한(자기 자신 포함 단계 수).
    public static let maxDepth = 32

    /// `pid` 자신부터 부모를 거슬러 올라가며 `matches` 가 처음 true 인 pid 를 반환한다.
    /// 순환(이미 방문한 pid)·pid <= 1(launchd/커널)·조회 실패·`maxDepth` 초과에서 멈추고 nil 을 반환한다.
    public static func firstAncestor(
        of pid: Int32, maxDepth: Int = ProcessAncestry.maxDepth,
        parentOf: (Int32) -> Int32?, matches: (Int32) -> Bool
    ) -> Int32? {
        var visited = Set<Int32>()
        var current = pid
        for _ in 0..<maxDepth {
            guard current > 1, visited.insert(current).inserted else { return nil }
            if matches(current) { return current }
            guard let parent = parentOf(current) else { return nil }
            current = parent
        }
        return nil
    }

    /// 커널이 기록한 부모 pid. 조회 실패 시 nil.
    public static func parentPid(of pid: Int32) -> Int32? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 0 ? parent : nil
    }
}
