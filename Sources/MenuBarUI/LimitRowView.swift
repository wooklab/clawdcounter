import AppKit
import CoreModels

/// 드롭다운 한도 한 줄의 표시 내용. `5시간 한도 [막대] 42% (2시간 13분)`.
struct LimitRowContent: Equatable {
    var label: String
    var percentText: String
    /// 괄호 포함 꼬리("(2시간 13분)", "(활성 창 없음)"). 없으면 nil.
    var remainingText: String?
    /// 0...1로 보정된 막대 채움 비율.
    var fraction: Double
    var level: UsageLevel
    /// 메뉴 항목 title 용 평문. 예: "5시간 한도 42% (2시간 13분)"
    var plainText: String
    /// 접근성 문장. 예: "5시간 한도 42퍼센트 남은 2시간 13분"
    var accessibilityText: String

    /// `noResetNote`: resetsAt 이 없을 때 꼬리로 붙일 문구(예: 5시간 창이 아직 시작되지 않음).
    init(label: String, window w: LimitWindow, now: Date, noResetNote: String? = nil) {
        let pct = Int(w.usedPercent.rounded())
        var tail: String?       // 괄호 안 문구
        var spoken: String?     // 접근성 꼬리
        if let resetsAt = w.resetsAt {
            let seconds = resetsAt.timeIntervalSince(now)
            tail = TimeFormat.remainingLong(seconds: seconds)
            spoken = TimeFormat.remainingPhrase(until: resetsAt, now: now)
        } else if let noResetNote {
            tail = noResetNote
            spoken = noResetNote
        }
        self.label = label
        self.percentText = "\(pct)%"
        self.remainingText = tail.map { "(\($0))" }
        self.fraction = min(1, max(0, w.usedPercent / 100))
        self.level = UsageLevel.level(forPercent: w.usedPercent)
        self.plainText = "\(label) \(pct)%" + (tail.map { " (\($0))" } ?? "")
        self.accessibilityText = "\(label) \(pct)퍼센트" + (spoken.map { " \($0)" } ?? "")
    }
}

/// 한도 줄 3개가 세로로 정렬되도록 공유하는 열 폭.
struct LimitColumns: Hashable {
    var label: CGFloat
    var percent: CGFloat
    var remaining: CGFloat

    @MainActor
    static func fitting(_ rows: [LimitRowContent]) -> LimitColumns {
        func width(_ s: String) -> CGFloat { ceil((s as NSString).size(withAttributes: [.font: LimitRowView.font]).width) }
        return LimitColumns(
            label: rows.map { width($0.label) }.max() ?? 0,
            percent: max(width("100%"), rows.map { width($0.percentText) }.max() ?? 0),
            remaining: rows.compactMap(\.remainingText).map(width).max() ?? 0)
    }
}

/// 한도 줄 커스텀 뷰: [라벨] [막대] [퍼센트(우측정렬)] [(남은시간)] 를 고정 열 폭으로 그린다.
/// 라벨색은 labelColor/secondaryLabelColor 라 라이트·다크 appearance 를 따른다.
final class LimitRowView: NSView {
    static let font = NSFont.menuFont(ofSize: 0)
    static let rowHeight: CGFloat = 22
    static let leadingInset: CGFloat = 14
    static let trailingInset: CGFloat = 14
    static let gap: CGFloat = 8
    static let barWidth: CGFloat = 100
    static let barHeight: CGFloat = 7

    let content: LimitRowContent
    let columns: LimitColumns

    init(content: LimitRowContent, columns: LimitColumns) {
        self.content = content
        self.columns = columns
        let hasTail = columns.remaining > 0
        let width = Self.leadingInset + columns.label + Self.gap + Self.barWidth + Self.gap + columns.percent
            + (hasTail ? Self.gap + columns.remaining : 0) + Self.trailingInset
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.rowHeight))
        autoresizingMask = [.width]
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(content.accessibilityText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: frame.width, height: Self.rowHeight) }

    // MARK: - 기하 (테스트용으로 노출)

    var barOriginX: CGFloat { Self.leadingInset + columns.label + Self.gap }

    /// 막대 채움 폭. 0% 는 채움 없음, 그 외에는 상태바 막대와 같이 최소 막대 높이(둥근 끝이 깨지지 않는 폭)를 보장한다.
    var barFillWidth: CGFloat {
        guard content.fraction > 0 else { return 0 }
        return max(Self.barHeight, Self.barWidth * CGFloat(content.fraction))
    }

    // MARK: - 그리기

    override func draw(_ dirtyRect: NSRect) {
        var x = Self.leadingInset
        drawText(content.label, in: x, width: columns.label, color: .labelColor, alignment: .left)
        x += columns.label + Self.gap

        let track = NSRect(x: x, y: ((bounds.height - Self.barHeight) / 2).rounded(), width: Self.barWidth, height: Self.barHeight)
        let radius = Self.barHeight / 2
        NSColor.labelColor.withAlphaComponent(0.2).setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()
        if barFillWidth > 0 {
            var fill = track
            fill.size.width = barFillWidth
            content.level.color.setFill()
            NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
        }
        x += Self.barWidth + Self.gap

        drawText(content.percentText, in: x, width: columns.percent, color: .labelColor, alignment: .right)
        x += columns.percent + Self.gap
        if let tail = content.remainingText {
            drawText(tail, in: x, width: columns.remaining, color: .secondaryLabelColor, alignment: .left)
        }
    }

    private func drawText(_ s: String, in x: CGFloat, width: CGFloat, color: NSColor, alignment: NSTextAlignment) {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = .byClipping
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: color, .paragraphStyle: style]
        let h = ceil((s as NSString).size(withAttributes: [.font: Self.font]).height)
        let rect = NSRect(x: x, y: ((bounds.height - h) / 2).rounded(), width: width, height: h)
        (s as NSString).draw(with: rect, options: [.usesLineFragmentOrigin], attributes: attrs)
    }
}
