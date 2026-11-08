import AppKit
import CoreModels

/// 세션 한 줄 커스텀 뷰: `● 활성 2   ● 응답대기 1   ○ 비활성 4`.
/// 점은 기존 세션 점 색(초록/노랑/라벨색 빈 원), 글자는 labelColor 라 라이트·다크 appearance 를 따른다.
/// NSMenuItem.attributedTitle 을 쓰면 item.title 이 꾸밈 문자열로 바뀌므로, 한도 줄처럼 view 로 그린다.
final class SessionRowView: NSView {
    static let font = NSFont.menuFont(ofSize: 0)
    static let rowHeight: CGFloat = 22
    static let leadingInset: CGFloat = 14
    static let trailingInset: CGFloat = 14
    static let separator = "   " // 항목 사이 3칸

    let counts: SessionCounts
    /// 화면에 그려지는 문자열(점 색 포함).
    let attributed: NSAttributedString

    static func plainText(_ s: SessionCounts) -> String { "활성 \(s.active) · 응답대기 \(s.waiting) · 비활성 \(s.idle)" }
    static func accessibilityText(_ s: SessionCounts) -> String {
        "활성 세션 \(s.active)개, 응답대기 세션 \(s.waiting)개, 비활성 세션 \(s.idle)개"
    }

    /// 세 항목은 0 이어도 항상 포함한다.
    static func attributedText(_ s: SessionCounts) -> NSAttributedString {
        let base: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.labelColor, .font: font]
        let entries: [(dot: String, color: NSColor, label: String)] = [
            ("●", .systemGreen, "활성 \(s.active)"),
            ("●", .systemYellow, "응답대기 \(s.waiting)"),
            ("○", .labelColor, "비활성 \(s.idle)"),
        ]
        let out = NSMutableAttributedString()
        for (i, e) in entries.enumerated() {
            if i > 0 { out.append(NSAttributedString(string: separator, attributes: base)) }
            out.append(NSAttributedString(string: e.dot, attributes: [.foregroundColor: e.color, .font: font]))
            out.append(NSAttributedString(string: " \(e.label)", attributes: base))
        }
        return out
    }

    init(counts: SessionCounts) {
        self.counts = counts
        self.attributed = Self.attributedText(counts)
        let width = Self.leadingInset + ceil(attributed.size().width) + Self.trailingInset
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.rowHeight))
        autoresizingMask = [.width]
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(Self.accessibilityText(counts))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: frame.width, height: Self.rowHeight) }

    override func draw(_ dirtyRect: NSRect) {
        let size = attributed.size()
        attributed.draw(at: NSPoint(x: Self.leadingInset, y: ((bounds.height - size.height) / 2).rounded()))
    }
}
