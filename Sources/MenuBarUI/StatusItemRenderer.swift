import AppKit
import CoreModels

/// 상태바 이미지 렌더러. 즉시(eager) 렌더링: 주어진 appearance 기준으로 비트맵(2x)에 그린다.
/// 템플릿 이미지가 아니므로 메뉴바 appearance가 바뀌면(`button.effectiveAppearance` 변경 감지)
/// 호출 측에서 다시 렌더링해야 한다.
public enum StatusItemRenderer {
    public static let height: CGFloat = 22
    static let scale: CGFloat = 2

    static let warnThreshold = 80.0
    static let criticalThreshold = 95.0

    enum Tone: Equatable { case normal, warn, critical }
    enum Dot { case active, idle, waiting }
    enum TextKind { case label, count }

    enum Element: Equatable {
        case text(String, TextKind)
        case bar(fraction: Double, tone: Tone)
        case dot(Dot)
    }

    /// 사용률(0-100) → 바 색조. 경계값 포함(80 → warn, 95 → critical).
    static func tone(forPercent p: Double) -> Tone {
        if p >= criticalThreshold { return .critical }
        if p >= warnThreshold { return .warn }
        return .normal
    }

    /// 사용량/인증 상태 → 앞쪽(텍스트·바) 요소. 세션 점 그룹은 `image`가 뒤에 항상 붙인다.
    static func leadingElements(usage: UsageSnapshot?, auth: AuthState, now: Date) -> [Element] {
        switch auth {
        case .signedOut: return [.text("로그인 필요", .label)]
        case .expired: return [.text("다시 로그인 필요", .label)]
        case .signingIn: return [.text("로그인 중…", .label)]
        case .signedIn: break
        }
        guard let usage, usage.fiveHour != nil || usage.weekly != nil else {
            return [.text("–", .label)]
        }
        var out: [Element] = []
        if let five = usage.fiveHour {
            let text = five.resetsAt.map { TimeFormat.remainingCompact(seconds: $0.timeIntervalSince(now)) } ?? "–"
            out.append(.text(text, .label))
            out.append(.bar(fraction: clamp(five.usedPercent / 100), tone: tone(forPercent: five.usedPercent)))
        }
        if let weekly = usage.weekly {
            out.append(.bar(fraction: clamp(weekly.usedPercent / 100), tone: tone(forPercent: weekly.usedPercent)))
        }
        return out
    }

    private static func clamp(_ x: Double) -> Double { min(1, max(0, x)) }

    private struct Placed { var element: Element; var x: CGFloat }

    @MainActor
    public static func image(
        usage: UsageSnapshot?,
        sessions: SessionCounts,
        auth: AuthState,
        now: Date = Date(),
        appearance: NSAppearance = NSApplication.shared.effectiveAppearance
    ) -> NSImage {
        let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let countFont = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
        func font(_ k: TextKind) -> NSFont { k == .label ? labelFont : countFont }

        // 1) 레이아웃
        var placed: [Placed] = []
        var x = sidePadding
        func place(_ e: Element, gap: CGFloat) {
            if !placed.isEmpty { x += gap }
            placed.append(Placed(element: e, x: x))
            switch e {
            case .text(let s, let k): x += ceil((s as NSString).size(withAttributes: [.font: font(k)]).width)
            case .bar: x += barSize.width
            case .dot: x += dotDiameter
            }
        }
        var prev: Element?
        for e in leadingElements(usage: usage, auth: auth, now: now) {
            var gap = groupGap
            if case .bar = e, case .bar? = prev { gap = innerGap + 1 }
            if case .bar = e, case .text? = prev { gap = innerGap + 2 }
            place(e, gap: gap)
            prev = e
        }
        let dots: [(Dot, Int)] = [(.active, sessions.active), (.idle, sessions.idle), (.waiting, sessions.waiting)]
        for (i, (dot, n)) in dots.enumerated() {
            place(.dot(dot), gap: i == 0 ? groupGap + 2 : groupGap - 1)
            place(.text(String(n), .count), gap: innerGap)
        }
        let width = ceil(x + sidePadding)
        let size = NSSize(width: width, height: height)

        // 2) 비트맵(2x)에 그리기
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        rep.size = size
        let ctx = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        appearance.performAsCurrentDrawingAppearance {
            for p in placed {
                switch p.element {
                case .text(let s, let k): drawText(s, font: font(k), x: p.x)
                case .bar(let f, let t): drawBar(fraction: f, tone: t, x: p.x)
                case .dot(let d): drawDot(d, x: p.x)
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: size)
        image.addRepresentation(rep)
        image.isTemplate = false
        return image
    }

    // MARK: - 치수

    private static let barSize = NSSize(width: 30, height: 7)
    private static let dotDiameter: CGFloat = 8
    private static let groupGap: CGFloat = 8
    private static let innerGap: CGFloat = 3
    private static let sidePadding: CGFloat = 2

    // MARK: - 그리기 (appearance가 설정된 컨텍스트 안에서만 호출)

    private static func drawText(_ s: String, font: NSFont, x: CGFloat) {
        // 수직 가운데: 숫자/영문 cap-height 기준 baseline (점·바 중심과 맞춘다)
        let y = ((height - font.capHeight) / 2).rounded() + font.descender // draw(at:)는 줄 하단 기준
        (s as NSString).draw(
            at: NSPoint(x: x, y: y),
            withAttributes: [.font: font, .foregroundColor: NSColor.labelColor]
        )
    }

    private static func drawBar(fraction: Double, tone: Tone, x: CGFloat) {
        let rect = NSRect(x: x, y: (height - barSize.height) / 2, width: barSize.width, height: barSize.height)
        let radius = barSize.height / 2
        NSColor.labelColor.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        guard fraction > 0 else { return }
        var fill = rect
        fill.size.width = max(barSize.height, rect.width * CGFloat(fraction))
        let color: NSColor
        switch tone {
        case .normal: color = .labelColor
        case .warn: color = .systemOrange
        case .critical: color = .systemRed
        }
        color.setFill()
        NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
    }

    private static func drawDot(_ dot: Dot, x: CGFloat) {
        let rect = NSRect(x: x, y: (height - dotDiameter) / 2, width: dotDiameter, height: dotDiameter)
        switch dot {
        case .active:
            NSColor.systemGreen.setFill()
            NSBezierPath(ovalIn: rect).fill()
        case .waiting:
            NSColor.systemYellow.setFill()
            NSBezierPath(ovalIn: rect).fill()
        case .idle:
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
            path.lineWidth = 1.5
            NSColor.labelColor.withAlphaComponent(0.85).setStroke()
            path.stroke()
        }
    }
}
