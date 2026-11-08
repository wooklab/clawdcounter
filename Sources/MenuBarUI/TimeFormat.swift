import CoreModels
import Foundation

/// 남은 시간 포맷터(순수 함수). `now`는 항상 주입받는다.
public enum TimeFormat {
    /// 드롭다운용 표기(`lang` 언어). 한국어 기준 1일↑ "D일 H시간", 1시간↑ "H시간 M분", 그 외 "M분".
    /// 0 단위는 생략("2시간 0분" → "2시간"). 1분 미만은 "1분 미만", 0 이하는 "곧 초기화".
    public static func remainingLong(seconds: TimeInterval, lang: Language = .current) -> String {
        guard seconds > 0 else { return L10n.tr(.resetsSoon, lang: lang) }
        let total = Int(seconds) // floor
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days >= 1 { return L10n.tr(hours == 0 ? .days(days) : .daysHours(days, hours), lang: lang) }
        if total >= 3_600 { return L10n.tr(minutes == 0 ? .hours(hours) : .hoursMinutes(hours, minutes), lang: lang) }
        if minutes >= 1 { return L10n.tr(.minutes(minutes), lang: lang) }
        return L10n.tr(.underOneMinute, lang: lang)
    }

    /// 상태바용 짧은 표기(모든 언어 공통). 1일↑ "1d3h", 1시간↑ "2h 13m"(시간·분 사이 공백, 분 2자리), 그 외 "45m", 1분 미만 "<1m", 0 이하 "0m".
    public static func remainingCompact(seconds: TimeInterval) -> String {
        guard seconds > 0 else { return "0m" }
        let total = Int(seconds)
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days >= 1 { return "\(days)d\(hours)h" }
        if total >= 3_600 { return "\(hours)h " + (minutes < 10 ? "0" : "") + "\(minutes)m" }
        if minutes >= 1 { return "\(minutes)m" }
        return "<1m"
    }

    /// 한도 줄의 꼬리: "남은 2시간 13분" / "곧 초기화". resetsAt이 없으면 nil.
    public static func remainingPhrase(until resetsAt: Date?, now: Date, lang: Language = .current) -> String? {
        guard let resetsAt else { return nil }
        let s = resetsAt.timeIntervalSince(now)
        return s > 0 ? L10n.tr(.remaining(remainingLong(seconds: s, lang: lang)), lang: lang) : L10n.tr(.resetsSoon, lang: lang)
    }
}
