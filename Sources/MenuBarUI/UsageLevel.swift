import AppKit

/// 사용률 단계(초록/노랑/주황/빨강). 상태바 바와 드롭다운 점이 같은 규칙·색을 쓰도록 여기 한 곳에 격리한다.
///
/// 단계 기준(제 판단, 하한 포함). 사용자는 "단계별 4색"만 요청했고 구간 경계는 지정하지 않았다:
///   - 0..<50  초록
///   - 50..<80 노랑
///   - 80..<95 주황
///   - 95...   빨강
/// 판정은 화면에 표시되는 정수 퍼센트(반올림) 기준이다. "80%"로 보이는데 노랑이면 어색하므로(예: 79.9 → 80 → 주황).
enum UsageLevel: Equatable {
    case green, yellow, orange, red

    static let yellowThreshold = 50.0
    static let orangeThreshold = 80.0
    static let redThreshold = 95.0

    /// 사용률(0-100 이상) → 단계.
    static func level(forPercent percent: Double) -> UsageLevel {
        let p = percent.rounded()
        if p >= redThreshold { return .red }
        if p >= orangeThreshold { return .orange }
        if p >= yellowThreshold { return .yellow }
        return .green
    }

    /// 단계 색. 라이트/다크 메뉴바 모두에서 읽히도록 노랑만 라이트에서 어둡게 보정한다.
    /// 동적 색이라 `performAsCurrentDrawingAppearance` 안에서 그리면 해당 appearance로 결정된다.
    var color: NSColor {
        switch self {
        case .green: return Self.greenColor
        case .yellow: return Self.yellowColor
        case .orange: return Self.orangeColor
        case .red: return Self.redColor
        }
    }

    private static let greenColor = NSColor.systemGreen
    private static let orangeColor = NSColor.systemOrange
    private static let redColor = NSColor.systemRed
    private static let yellowColor = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark ? NSColor.systemYellow : NSColor(srgbRed: 0.78, green: 0.60, blue: 0.0, alpha: 1)
    }
}
