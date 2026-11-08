import AppKit

/// 세션 구획의 비클릭 행(헤더 `● 활성 2`, `외 N개`): 커스텀 뷰로 그려 비활성(회색) 항목 스타일을 피한다.
/// 글자색은 labelColor(라이트·다크 appearance 를 따름), 선두 점만 지정 색.
final class SessionRowView: NSView {
    static let font = NSFont.menuFont(ofSize: 0)
    static let rowHeight: CGFloat = 22
    static let leadingInset: CGFloat = 14
    static let trailingInset: CGFloat = 14

    let text: String
    let dotColor: NSColor?
    /// 선두 글자(점)만 `dotColor`, 나머지는 labelColor.
    let attributedText: NSAttributedString

    init(text: String, dotColor: NSColor? = nil, accessibilityText: String) {
        self.text = text
        self.dotColor = dotColor
        let attributed = NSMutableAttributedString(
            string: text, attributes: [.foregroundColor: NSColor.labelColor, .font: Self.font])
        if let dotColor, !text.isEmpty {
            attributed.addAttribute(.foregroundColor, value: dotColor, range: NSRange(location: 0, length: 1))
        }
        attributedText = attributed
        let width = Self.leadingInset + ceil(attributed.size().width) + Self.trailingInset
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.rowHeight))
        autoresizingMask = [.width]
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(accessibilityText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: frame.width, height: Self.rowHeight) }

    override func draw(_ dirtyRect: NSRect) {
        let size = attributedText.size()
        attributedText.draw(at: NSPoint(x: Self.leadingInset, y: ((bounds.height - size.height) / 2).rounded()))
    }
}
