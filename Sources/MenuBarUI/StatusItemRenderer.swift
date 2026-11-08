import AppKit
import CoreModels

/// 상태바 이미지 렌더러. 즉시(eager) 렌더링: 주어진 appearance 기준으로 비트맵(2x)에 그린다.
/// 템플릿 이미지가 아니므로 메뉴바 appearance가 바뀌면(`button.effectiveAppearance` 변경 감지)
/// 호출 측에서 다시 렌더링해야 한다.
public enum StatusItemRenderer {
    public static let height: CGFloat = 22
    static let scale: CGFloat = 2

    enum TextKind { case label, count }

    enum Element: Equatable {
        case text(String, TextKind)
        case bar(fraction: Double, level: UsageLevel)
    }

    /// 사용량/인증 상태 → 앞쪽(텍스트·바) 요소. 텍스트는 왼쪽, 바(5h→주간 순)는 세로로 쌓이며, 세션 묶음은 `image`가 우측에 항상 붙인다.
    static func leadingElements(usage: UsageSnapshot?, auth: AuthState, now: Date, lang: Language = .current) -> [Element] {
        switch auth {
        case .signedOut: return [.text(L10n.tr(.statusLoginRequired, lang: lang), .label)]
        case .expired: return [.text(L10n.tr(.statusLoginAgain, lang: lang), .label)]
        case .signingIn: return [.text(L10n.tr(.loggingIn, lang: lang), .label)]
        case .signedIn: break
        }
        guard let usage, usage.fiveHour != nil || usage.weekly != nil else {
            return [.text("–", .label)]
        }
        var out: [Element] = []
        if let five = usage.fiveHour {
            let text = five.resetsAt.map { TimeFormat.remainingCompact(seconds: $0.timeIntervalSince(now)) } ?? "–"
            out.append(.text(text, .label))
            out.append(.bar(fraction: clamp(five.usedPercent / 100), level: UsageLevel.level(forPercent: five.usedPercent)))
        }
        if let weekly = usage.weekly {
            out.append(.bar(fraction: clamp(weekly.usedPercent / 100), level: UsageLevel.level(forPercent: weekly.usedPercent)))
        }
        return out
    }

    private static func clamp(_ x: Double) -> Double { min(1, max(0, x)) }

    @MainActor
    public static func image(
        usage: UsageSnapshot?,
        sessions: SessionCounts,
        auth: AuthState,
        now: Date = Date(),
        appearance: NSAppearance = NSApplication.shared.effectiveAppearance,
        lang: Language = .current
    ) -> NSImage {
        let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let sessionFont = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold)
        let waitingCountFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        let emojiFont = NSFont(name: "Apple Color Emoji", size: 14) ?? NSFont.systemFont(ofSize: 14)

        // 1) 레이아웃: [텍스트] [바 세로 묶음] | [세션 점 세로 묶음] [✋ (+개수)]
        let leading = leadingElements(usage: usage, auth: auth, now: now, lang: lang)
        var texts: [(String, CGFloat)] = []   // (문자열, x)
        var bars: [(fraction: Double, level: UsageLevel)] = []
        var x = sidePadding
        for e in leading {
            switch e {
            case .text(let s, _):
                texts.append((s, x))
                x += ceil((s as NSString).size(withAttributes: [.font: labelFont]).width) + innerGap + 2
            case .bar(let f, let l):
                bars.append((f, l))
            }
        }
        let barsX = x
        if !bars.isEmpty { x += barWidth + groupGap }
        else if !texts.isEmpty { x += groupGap - innerGap - 2 }

        // 세션 묶음(우측): 위 = 활성(채운 원), 아래 = 비활성(빈 원)
        let activeText = String(sessions.active), idleText = String(sessions.idle)
        func textWidth(_ s: String, _ f: NSFont) -> CGFloat { ceil((s as NSString).size(withAttributes: [.font: f]).width) }
        let numberWidth = max(textWidth(activeText, sessionFont), textWidth(idleText, sessionFont))
        let sessionsX = x
        x += dotDiameter + innerGap + numberWidth

        // 응답대기: waiting > 0 일 때만 ✋ 를 우측에 붙인다. 폭 0이면 아무것도 그리지 않는다.
        // 개수 표기는 제 판단: 1이면 이모지만, 2 이상이면 이모지 뒤에 숫자.
        let waitingX = x + groupGap - 2
        var waitingCountX: CGFloat?
        if sessions.waiting > 0 {
            x = waitingX + textWidth(waitingEmoji, emojiFont)
            if sessions.waiting >= 2 {
                waitingCountX = x + 1.5
                x = waitingCountX! + textWidth(String(sessions.waiting), waitingCountFont)
            }
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
            for (s, tx) in texts { drawText(s, font: labelFont, x: tx, centerY: height / 2) }

            // 바: 위 = 5시간, 아래 = 주간. 하나뿐이면 세로 중앙.
            let stackH = CGFloat(bars.count) * barHeight + CGFloat(max(0, bars.count - 1)) * barGap
            let top = height / 2 + stackH / 2
            for (i, b) in bars.enumerated() {
                let y = snap(top - barHeight - CGFloat(i) * (barHeight + barGap))
                drawBar(fraction: b.fraction, level: b.level, x: barsX, y: y)
            }

            let rowCenters = (top: height * 0.75, bottom: height * 0.25)
            drawDot(filled: true, x: sessionsX, centerY: rowCenters.top)
            drawText(activeText, font: sessionFont, x: sessionsX + dotDiameter + innerGap, centerY: rowCenters.top)
            drawDot(filled: false, x: sessionsX, centerY: rowCenters.bottom)
            drawText(idleText, font: sessionFont, x: sessionsX + dotDiameter + innerGap, centerY: rowCenters.bottom)

            if sessions.waiting > 0 {
                drawEmoji(waitingEmoji, font: emojiFont, x: waitingX)
                if let cx = waitingCountX {
                    drawText(String(sessions.waiting), font: waitingCountFont, x: cx, centerY: height / 2)
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

    static let waitingEmoji = "✋\u{FE0F}"
    private static let barWidth: CGFloat = 30
    private static let barHeight: CGFloat = 4.5
    private static let barGap: CGFloat = 2
    private static let dotDiameter: CGFloat = 6
    private static let groupGap: CGFloat = 8
    private static let innerGap: CGFloat = 3
    private static let sidePadding: CGFloat = 2

    /// 2x 비트맵에서 픽셀 경계(0.5pt)에 맞춘다.
    private static func snap(_ v: CGFloat) -> CGFloat { (v * 2).rounded() / 2 }

    // MARK: - 그리기 (appearance가 설정된 컨텍스트 안에서만 호출)

    private static func drawText(_ s: String, font: NSFont, x: CGFloat, centerY: CGFloat) {
        // 수직 가운데: 숫자/영문 cap-height 중심을 centerY에 맞춘다. draw(at:)는 줄 하단 기준.
        let y = snap(centerY - font.capHeight / 2) + font.descender
        (s as NSString).draw(
            at: NSPoint(x: x, y: y),
            withAttributes: [.font: font, .foregroundColor: NSColor.labelColor]
        )
    }

    private static func drawEmoji(_ s: String, font: NSFont, x: CGFloat) {
        let h = (s as NSString).size(withAttributes: [.font: font]).height
        (s as NSString).draw(at: NSPoint(x: x, y: snap((height - h) / 2)), withAttributes: [.font: font])
    }

    private static func drawBar(fraction: Double, level: UsageLevel, x: CGFloat, y: CGFloat) {
        let rect = NSRect(x: x, y: y, width: barWidth, height: barHeight)
        let radius = barHeight / 2
        NSColor.labelColor.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        guard fraction > 0 else { return }
        var fill = rect
        fill.size.width = max(barHeight, rect.width * CGFloat(fraction))
        level.color.setFill()
        NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
    }

    private static func drawDot(filled: Bool, x: CGFloat, centerY: CGFloat) {
        let rect = NSRect(x: x, y: centerY - dotDiameter / 2, width: dotDiameter, height: dotDiameter)
        if filled {
            NSColor.systemGreen.setFill()
            NSBezierPath(ovalIn: rect).fill()
        } else {
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: 0.6, dy: 0.6))
            path.lineWidth = 1.2
            NSColor.labelColor.withAlphaComponent(0.85).setStroke()
            path.stroke()
        }
    }
}
