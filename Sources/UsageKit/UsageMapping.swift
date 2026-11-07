import CoreModels
import Foundation

/// 사용량 API 응답 JSON -> `UsageSnapshot` 매핑. 실제 응답 형태가 확인되면 이 파일만 고친다.
///
/// 현재는 **추정** 형태를 관대하게 해석한다:
/// ```
/// {
///   "five_hour":  { "utilization": 0-100, "resets_at": ISO8601|epoch } | null,
///   "seven_day":  { ... } | null,
///   "seven_day_opus" / "seven_day_sonnet" / "seven_day_fable" ...: { ... } | null,   // 'seven_day_*' 접두
///   "extra_usage": { "is_enabled": Bool, "monthly_limit": n|null, "used_credits": n|null, "utilization": n|null },
///   "<ticket 이 이름에 들어간 키>": { "remaining": n, "total": n } | n
/// }
/// ```
/// 윈도우의 퍼센트 키는 `utilization` / `used_percentage` / `used_percent` / `percent` 를 순서대로 시도.
enum UsageMapping {
    struct Result: Equatable {
        var snapshot: UsageSnapshot
        /// 매핑에서 사용하지 않은 키 경로(값 제외). 예: `iguana_necktie`, `five_hour.foo`.
        var unmappedKeys: [String]
    }

    static func map(_ data: Data, fetchedAt: Date) throws -> Result {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw UsageError.invalidResponse
        }
        var unmapped = Set<String>()
        var consumed = Set<String>()

        func window(_ key: String) -> LimitWindow? {
            consumed.insert(key)
            guard let dict = root[key] as? [String: Any] else { return nil } // null/누락/타입 불일치 = 한도 없음
            let (w, extra) = parseWindow(dict)
            unmapped.formUnion(extra.map { "\(key).\($0)" })
            return w
        }

        var fable: LimitWindow?
        for key in root.keys.sorted() where key.hasPrefix("seven_day_") && key.lowercased().contains("fable") {
            if let w = window(key) { fable = w; break }
        }

        var snapshot = UsageSnapshot(
            fiveHour: window("five_hour"),
            weekly: window("seven_day"),
            fable: fable,
            fetchedAt: fetchedAt
        )

        if let dict = root["extra_usage"] as? [String: Any] {
            let (credit, extra) = parseCredit(dict)
            snapshot.credit = credit
            unmapped.formUnion(extra.map { "extra_usage.\($0)" })
        }
        consumed.insert("extra_usage")

        for key in root.keys.sorted() where key.lowercased().contains("ticket") {
            consumed.insert(key)
            if let t = parseTickets(root[key]) { snapshot.resetTickets = t; break }
        }

        unmapped.formUnion(root.keys.filter { !consumed.contains($0) })
        return Result(snapshot: snapshot, unmappedKeys: unmapped.sorted())
    }

    // MARK: - 개별 파서

    private static let percentKeys = ["utilization", "used_percentage", "used_percent", "percent"]
    private static let resetKeys = ["resets_at", "reset_at"]

    static func parseWindow(_ dict: [String: Any]) -> (LimitWindow?, unusedKeys: [String]) {
        let percent = percentKeys.lazy.compactMap { number(dict[$0]) }.first
        let resets = resetKeys.lazy.compactMap { date(dict[$0]) }.first
        let unused = dict.keys.filter { !percentKeys.contains($0) && !resetKeys.contains($0) }
        guard let percent else { return (nil, unused.sorted()) }
        return (LimitWindow(usedPercent: percent, resetsAt: resets), unused.sorted())
    }

    static func parseCredit(_ dict: [String: Any]) -> (CreditUsage?, unusedKeys: [String]) {
        let known: Set<String> = ["is_enabled", "monthly_limit", "used_credits", "utilization", "currency"]
        let unused = dict.keys.filter { !known.contains($0) }.sorted()
        if let enabled = dict["is_enabled"] as? Bool, !enabled { return (nil, unused) }
        guard let limit = number(dict["monthly_limit"]), let used = number(dict["used_credits"]) else {
            return (nil, unused)
        }
        return (CreditUsage(used: used, total: limit, unit: dict["currency"] as? String), unused)
    }

    static func parseTickets(_ value: Any?) -> ResetTicketStatus? {
        if let n = number(value) { return ResetTicketStatus(remaining: Int(n)) }
        guard let dict = value as? [String: Any], let remaining = number(dict["remaining"]) else { return nil }
        return ResetTicketStatus(remaining: Int(remaining), total: number(dict["total"]).map { Int($0) })
    }

    // MARK: - 값 변환

    /// Bool 은 NSNumber 로 오므로 제외한다.
    static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    /// ISO8601 문자열(소수초 자릿수 무관, `+00:00`/`Z`) 또는 epoch(초/밀리초).
    static func date(_ value: Any?) -> Date? {
        if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
            return epoch(n.doubleValue)
        }
        guard let s = value as? String, !s.isEmpty else { return nil }
        if let d = Double(s) { return epoch(d) }
        // 소수초를 3자리로 정규화(파이썬 isoformat 의 마이크로초 대응)
        let normalized = s.replacingOccurrences(
            of: #"(\.\d{3})\d+"#, with: "$1", options: .regularExpression
        )
        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = frac.date(from: normalized) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: normalized)
    }

    private static func epoch(_ v: Double) -> Date {
        Date(timeIntervalSince1970: v > 100_000_000_000 ? v / 1000 : v)
    }
}
