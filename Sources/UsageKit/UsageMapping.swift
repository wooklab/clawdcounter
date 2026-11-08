import CoreModels
import Foundation

/// 사용량 API 응답 JSON -> `UsageSnapshot` 매핑.
///
/// 실제 응답(Max 5x 계정)에서 확인된 형태:
/// ```
/// {
///   "five_hour": { "utilization": 0.0, "resets_at": null | ISO8601, ... } | null,
///   "seven_day": { "utilization": 5.0, "resets_at": "2026-11-14T13:59:59.802996+00:00", ... } | null,
///   "seven_day_opus" / "seven_day_sonnet" / ...: null,       // 난수성 이름 키 대부분 null
///   "extra_usage": { "is_enabled": false, "monthly_limit": null, "used_credits": null, ... },
///   "limits": [ { "kind": "session"|"weekly_all"|..., "group", "percent", "resets_at", "scope", "is_active" } ],
///   "spend": { "used": {"amount_minor": 0, "currency": "USD", "exponent": 2}, "limit": null, "cap": null,
///              "balance": null, "enabled": false, ... }
/// }
/// ```
/// - `five_hour.resets_at == null` 은 "활성 5시간 창 없음"이지 한도 없음이 아니다 -> `LimitWindow(usedPercent:, resetsAt: nil)`.
/// - 최상위 `five_hour`/`seven_day` 가 없거나 null 이면 `limits` 의 `session`/`weekly_all` 로 폴백.
/// - Fable: `seven_day_*fable*` 키, 없으면 `limits` 중 kind/scope 에 "fable" 이 든 항목. 둘 다 없으면 nil(비노출).
/// - 세션 초기화 티켓: 실제 응답에서 해당 필드를 찾지 못했다. 이름에 "ticket" 이 든 키를 찾는 추정 매핑만 유지.
/// 윈도우의 퍼센트 키는 `utilization` / `used_percentage` / `used_percent` / `percent` 를 순서대로 시도.
enum UsageMapping {
    struct Result: Equatable {
        var snapshot: UsageSnapshot
        /// 매핑에서 사용하지 않은 **null 이 아닌** 키 경로(값 제외). 예: `iguana_necktie`, `five_hour.foo`.
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
            guard let dict = root[key] as? [String: Any] else { return nil } // null/누락/타입 불일치 = 최상위엔 한도 없음
            let (w, extra) = parseWindow(dict)
            unmapped.formUnion(extra.map { "\(key).\($0)" })
            return w
        }

        // limits 배열(폴백용). 항목별 미매핑 키는 보고하지 않는다.
        consumed.insert("limits")
        let limits = (root["limits"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
        func fromLimits(_ match: ([String: Any]) -> Bool) -> LimitWindow? {
            for item in limits where match(item) {
                if let w = parseWindow(item).0 { return w }
            }
            return nil
        }
        func kind(_ item: [String: Any]) -> String? { (item["kind"] as? String)?.lowercased() }
        func isFable(_ item: [String: Any]) -> Bool { mentionsFable(item["kind"]) || mentionsFable(item["scope"]) }

        var fable: LimitWindow?
        for key in root.keys.sorted() where key.hasPrefix("seven_day_") && key.lowercased().contains("fable") {
            if let w = window(key) { fable = w; break }
        }
        fable = fable ?? fromLimits(isFable)

        var snapshot = UsageSnapshot(
            fiveHour: window("five_hour") ?? fromLimits { !isFable($0) && kind($0) == "session" },
            weekly: window("seven_day") ?? fromLimits { !isFable($0) && kind($0) == "weekly_all" },
            fable: fable,
            fetchedAt: fetchedAt
        )

        // 크레딧: spend 가 1순위, 실패하면 extra_usage(is_enabled == true 일 때만). spend.enabled == false 면 비활성으로 확정.
        consumed.insert("spend")
        consumed.insert("extra_usage")
        var extraCredit: CreditUsage?
        if let dict = root["extra_usage"] as? [String: Any] {
            let (credit, extra) = parseExtraUsage(dict)
            extraCredit = credit
            unmapped.formUnion(extra.map { "extra_usage.\($0)" })
        }
        if let spend = root["spend"] as? [String: Any] {
            if (spend["enabled"] as? Bool) == false {
                snapshot.credit = nil
            } else {
                snapshot.credit = parseSpend(spend) ?? extraCredit
            }
        } else {
            snapshot.credit = extraCredit
        }

        for key in root.keys.sorted() where key.lowercased().contains("ticket") {
            consumed.insert(key)
            if let t = parseTickets(root[key]) { snapshot.resetTickets = t; break }
        }

        unmapped.formUnion(root.filter { !consumed.contains($0.key) && !($0.value is NSNull) }.keys)
        return Result(snapshot: snapshot, unmappedKeys: unmapped.sorted())
    }

    // MARK: - 개별 파서

    private static let percentKeys = ["utilization", "used_percentage", "used_percent", "percent"]
    private static let resetKeys = ["resets_at", "reset_at"]

    /// 퍼센트가 없으면 nil. `resets_at` 이 null 이어도 퍼센트가 있으면 윈도우는 존재한다(resetsAt == nil).
    static func parseWindow(_ dict: [String: Any]) -> (LimitWindow?, unusedKeys: [String]) {
        let percent = percentKeys.lazy.compactMap { number(dict[$0]) }.first
        let resets = resetKeys.lazy.compactMap { date(dict[$0]) }.first
        let unused = dict.filter { !percentKeys.contains($0.key) && !resetKeys.contains($0.key) && !($0.value is NSNull) }.keys
        guard let percent else { return (nil, unused.sorted()) }
        return (LimitWindow(usedPercent: percent, resetsAt: resets), unused.sorted())
    }

    /// `extra_usage`: `is_enabled == true` 일 때만 `monthly_limit`/`used_credits` 를 사용.
    static func parseExtraUsage(_ dict: [String: Any]) -> (CreditUsage?, unusedKeys: [String]) {
        let known: Set<String> = ["is_enabled", "monthly_limit", "used_credits", "utilization", "currency"]
        let unused = dict.filter { !known.contains($0.key) && !($0.value is NSNull) }.keys.sorted()
        guard (dict["is_enabled"] as? Bool) == true,
              let limit = number(dict["monthly_limit"]), let used = number(dict["used_credits"]) else {
            return (nil, unused)
        }
        return (CreditUsage(used: used, total: limit, unit: dict["currency"] as? String), unused)
    }

    /// **가정**: 활성화된 `spend` 의 형태는 실제로 본 적이 없다(비활성 응답만 확인).
    /// `enabled == true` 이면 used = used.amount_minor / 10^exponent, total = limit -> cap -> balance 중
    /// 처음으로 같은 형태(amount_minor/exponent)의 money 객체인 값, unit = used.currency.
    /// total 을 알 수 없으면 nil(비노출).
    static func parseSpend(_ dict: [String: Any]) -> CreditUsage? {
        guard (dict["enabled"] as? Bool) == true, let used = money(dict["used"]) else { return nil }
        guard let total = ["limit", "cap", "balance"].lazy.compactMap({ money(dict[$0]) }).first else { return nil }
        return CreditUsage(used: used.value, total: total.value, unit: used.currency ?? total.currency)
    }

    /// `{"amount_minor": 1234, "currency": "USD", "exponent": 2}` -> 12.34. 필드가 하나라도 없으면 nil.
    static func money(_ value: Any?) -> (value: Double, currency: String?)? {
        guard let dict = value as? [String: Any],
              let minor = number(dict["amount_minor"]), let exponent = number(dict["exponent"]) else { return nil }
        return (minor / pow(10, exponent), dict["currency"] as? String)
    }

    static func parseTickets(_ value: Any?) -> ResetTicketStatus? {
        if let n = number(value) { return ResetTicketStatus(remaining: Int(n)) }
        guard let dict = value as? [String: Any], let remaining = number(dict["remaining"]) else { return nil }
        return ResetTicketStatus(remaining: Int(remaining), total: number(dict["total"]).map { Int($0) })
    }

    /// 문자열이면 그대로, 객체/배열이면 설명 문자열에서 "fable" 포함 여부 검사(대소문자 무시).
    private static func mentionsFable(_ value: Any?) -> Bool {
        switch value {
        case nil, is NSNull: return false
        case let s as String: return s.lowercased().contains("fable")
        default: return String(describing: value!).lowercased().contains("fable")
        }
    }

    // MARK: - 값 변환

    /// Bool 은 NSNumber 로 오므로 제외한다.
    static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    /// ISO8601 문자열(소수초 자릿수 무관 — 마이크로초까지 보존, `+00:00`/`Z`) 또는 epoch(초/밀리초).
    static func date(_ value: Any?) -> Date? {
        if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
            return epoch(n.doubleValue)
        }
        guard var s = value as? String, !s.isEmpty else { return nil }
        if let d = Double(s) { return epoch(d) }
        // ISO8601DateFormatter 의 소수초는 자릿수에 민감하므로 소수부를 떼어 따로 더한다.
        var fraction = 0.0
        if let r = s.range(of: #"\.\d+"#, options: .regularExpression) {
            fraction = Double("0" + s[r]) ?? 0
            s.removeSubrange(r)
        }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)?.addingTimeInterval(fraction)
    }

    private static func epoch(_ v: Double) -> Date {
        Date(timeIntervalSince1970: v > 100_000_000_000 ? v / 1000 : v)
    }
}
