import Foundation
import Darwin

/// pid 생존 확인 및 pid 재사용 방지용 시작 시각 비교.
enum ProcessProbe {
    /// `kill(pid, 0)`: 성공 또는 EPERM(권한 없음, 프로세스는 존재)이면 생존.
    static func isAlive(_ pid: Int) -> Bool {
        guard pid > 0, pid <= Int(Int32.max) else { return false }
        if kill(pid_t(pid), 0) == 0 { return true }
        return errno == EPERM
    }

    /// 커널이 기록한 프로세스 시작 시각. 조회 실패 시 nil.
    static func startTime(of pid: Int) -> Date? {
        guard pid > 0, pid <= Int(Int32.max) else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(pid)]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let tv = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
    }

    /// 세션 파일의 `procStart`("Sat Nov  7 14:34:21 2026", `ps lstart` 형식)가
    /// 실제 프로세스 시작 시각과 같은 프로세스를 가리키는지.
    /// 관찰상 파일 값은 UTC, `ps`는 로컬 시간이라 두 해석 중 하나만 맞아도 일치로 본다.
    /// 파싱/조회 불가 시 nil(판단 불가 → 호출 측은 생존으로 취급).
    static func procStartMatches(_ procStart: String, pid: Int) -> Bool? {
        guard let actual = startTime(of: pid) else { return nil }
        return procStartMatches(procStart, actualStart: actual)
    }

    static func procStartMatches(_ procStart: String, actualStart actual: Date, tolerance: TimeInterval = 2) -> Bool? {
        let parts = procStart.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard parts.count == 5,
              let month = months.firstIndex(of: parts[1]).map({ $0 + 1 }),
              let day = Int(parts[2]),
              let year = Int(parts[4])
        else { return nil }
        let hms = parts[3].split(separator: ":").compactMap { Int($0) }
        guard hms.count == 3 else { return nil }

        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        comps.hour = hms[0]; comps.minute = hms[1]; comps.second = hms[2]

        var parsedAny = false
        for tz in [TimeZone(identifier: "UTC"), TimeZone.current] {
            var cal = Calendar(identifier: .gregorian)
            guard let tz else { continue }
            cal.timeZone = tz
            guard let date = cal.date(from: comps) else { continue }
            parsedAny = true
            if abs(date.timeIntervalSince(actual)) <= tolerance { return true }
        }
        return parsedAny ? false : nil
    }

    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
}
