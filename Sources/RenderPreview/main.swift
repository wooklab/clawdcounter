import AppKit
import CoreModels
import MenuBarUI

// 상태바 이미지를 언어 × 케이스 × (light|dark)별 PNG로, 메뉴 구조를 텍스트로 build/preview/<언어>/ 에 출력한다.
// 실행: swift run --scratch-path .build-ui RenderPreview   (프로젝트 루트에서)

_ = NSApplication.shared

let now = Date(timeIntervalSince1970: 1_800_000_000)
func win(_ pct: Double, in seconds: TimeInterval) -> LimitWindow {
    LimitWindow(usedPercent: pct, resetsAt: now.addingTimeInterval(seconds))
}
let h: TimeInterval = 3600
let counts = SessionCounts(
    active: 2, waiting: 1, idle: 4,
    activeSessions: ["clawdcounter 드롭다운", "맥북 메뉴바 표시 제거"].map { SessionRef(name: $0) },
    waitingSessions: [SessionRef(name: "상태바 앱 이름 추천")],
    idleSessions: ["btw: sfltool 권한", "docs", "refactor-auth"].map { SessionRef(name: $0) }
        + [SessionRef(name: "", placeholder: .unnamed)])

let full = UsageSnapshot(
    fiveHour: win(42, in: 2 * h + 13 * 60),
    weekly: win(63, in: 3 * 86400 + 5 * h),
    fable: win(18, in: 3 * 86400 + 5 * h),
    credit: CreditUsage(used: 12.5, total: 100, unit: "USD"),
    resetTickets: ResetTicketStatus(remaining: 2),
    fetchedAt: now
)

struct Case {
    var name: String
    var usage: UsageSnapshot?
    var sessions: SessionCounts
    var auth: AuthState
}

var noFive = full; noFive.fiveHour = nil
var noFable = full; noFable.fable = nil
var high = full
high.fiveHour = win(96, in: 25 * 60)
high.weekly = win(82, in: 86400 + 3 * h)
var warnOnly = full
warnOnly.fiveHour = win(80, in: 4 * h)
warnOnly.weekly = win(79.9, in: 5 * 86400)
var minimal = UsageSnapshot(weekly: win(10, in: 6 * 86400), fetchedAt: now)
minimal.credit = nil

// 실제 응답 형태(Max 5x): 활성 5시간 창 없음, 주간 5%, 추가 크레딧 꺼짐($0.00), Fable/티켓 없음
let fiveHourInactive = UsageSnapshot(
    fiveHour: LimitWindow(usedPercent: 0, resetsAt: nil), weekly: win(5, in: 6 * 86400 + 4 * h),
    credit: CreditUsage(used: 0, total: nil, unit: "USD", isEnabled: false), fetchedAt: now)
var creditNoTotal = full; creditNoTotal.credit = CreditUsage(used: 12.5, total: nil, unit: "USD")
var creditDisabledWithTotal = full; creditDisabledWithTotal.credit = CreditUsage(used: 0, total: 20, unit: "USD", isEnabled: false)
var creditEUR = full; creditEUR.credit = CreditUsage(used: 12.5, total: 100, unit: "EUR")

// 단계별 확인: 5시간·주간이 같은 값, 그리고 서로 다른 단계 조합
func levelCase(_ pct: Double) -> Case {
    let u = UsageSnapshot(
        fiveHour: win(pct, in: 2 * h), weekly: win(pct, in: 3 * 86400), fable: win(pct, in: 3 * 86400), fetchedAt: now)
    return Case(name: "level-\(Int(pct))", usage: u, sessions: counts, auth: .signedIn)
}
let levelCases = [10.0, 49, 50, 79, 80, 94, 95, 100].map(levelCase)
let mixedLevels = UsageSnapshot(
    fiveHour: win(85, in: h), weekly: win(30, in: 3 * 86400), fable: win(55, in: 3 * 86400), fetchedAt: now)

let cases: [Case] = levelCases + [
    Case(name: "level-mixed-5h85-wk30", usage: mixedLevels, sessions: counts, auth: .signedIn),
    Case(name: "five-hour", usage: full, sessions: counts, auth: .signedIn),
    Case(name: "five-hour-inactive", usage: fiveHourInactive, sessions: counts, auth: .signedIn),
    Case(name: "no-five-hour", usage: noFive, sessions: counts, auth: .signedIn),
    Case(name: "credit-disabled", usage: fiveHourInactive, sessions: counts, auth: .signedIn),
    Case(name: "credit-disabled-with-total", usage: creditDisabledWithTotal, sessions: counts, auth: .signedIn),
    Case(name: "credit-no-total", usage: creditNoTotal, sessions: counts, auth: .signedIn),
    Case(name: "credit-eur", usage: creditEUR, sessions: counts, auth: .signedIn),
    Case(name: "no-fable", usage: noFable, sessions: counts, auth: .signedIn),
    Case(name: "waiting-0", usage: full, sessions: SessionCounts(active: 2, waiting: 0, idle: 4), auth: .signedIn),
    Case(name: "waiting-1", usage: full, sessions: SessionCounts(active: 2, waiting: 1, idle: 4), auth: .signedIn),
    Case(name: "waiting-3", usage: full, sessions: SessionCounts(active: 2, waiting: 3, idle: 4), auth: .signedIn),
    Case(name: "sessions-zero", usage: full, sessions: SessionCounts(active: 0, waiting: 0, idle: 0), auth: .signedIn),
    Case(name: "signed-out", usage: nil, sessions: counts, auth: .signedOut),
    Case(name: "expired", usage: full, sessions: counts, auth: .expired),
    Case(name: "high-usage", usage: high, sessions: counts, auth: .signedIn),
    Case(name: "threshold-80", usage: warnOnly, sessions: counts, auth: .signedIn),
    Case(name: "loading", usage: nil, sessions: counts, auth: .signedIn),
    Case(name: "many-sessions", usage: full, sessions: SessionCounts(active: 12, waiting: 10, idle: 25), auth: .signedIn),
    Case(name: "minimal-weekly-only", usage: minimal, sessions: counts, auth: .signedIn),
]

/// 언어별 출력 폴더: build/preview/<ko|en|zh-Hans|ja>/
func outDir(_ lang: Language) throws -> URL {
    let url = URL(fileURLWithPath: "build/preview", isDirectory: true).appendingPathComponent(lang.rawValue, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

enum Mode: String, CaseIterable {
    case light, dark
    var appearance: NSAppearance { NSAppearance(named: self == .light ? .aqua : .darkAqua)! }
    /// 메뉴바와 비슷한 배경색(투명 PNG에서 labelColor가 안 보이는 착시 방지)
    var background: NSColor {
        self == .light ? NSColor(srgbRed: 0.93, green: 0.93, blue: 0.93, alpha: 1)
                       : NSColor(srgbRed: 0.16, green: 0.16, blue: 0.16, alpha: 1)
    }
}

let scale = 3
func png(compositing images: [NSImage], captions: [String]?, mode: Mode) -> Data {
    let pad: CGFloat = 8
    let captionW: CGFloat = captions == nil ? 0 : 150
    let width = ceil((images.map { $0.size.width }.max() ?? 0) + pad * 2 + captionW)
    let rowH = StatusItemRenderer.height
    let height = pad * 2 + CGFloat(images.count) * rowH + CGFloat(max(0, images.count - 1)) * 4
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(width) * scale, pixelsHigh: Int(height) * scale,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    mode.appearance.performAsCurrentDrawingAppearance {
        mode.background.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        for (i, img) in images.enumerated() {
            let y = height - pad - rowH * CGFloat(i + 1) - 4 * CGFloat(i)
            img.draw(in: NSRect(x: pad, y: y, width: img.size.width, height: rowH))
            if let captions {
                (captions[i] as NSString).draw(
                    at: NSPoint(x: width - captionW + 4, y: y + 5),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor])
            }
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var written: [String] = []
for lang in Language.allCases {
    for mode in Mode.allCases {
        var images: [NSImage] = []
        for c in cases {
            let img = StatusItemRenderer.image(
                usage: c.usage, sessions: c.sessions, auth: c.auth, now: now, appearance: mode.appearance, lang: lang)
            images.append(img)
            let url = try outDir(lang).appendingPathComponent("\(c.name)-\(mode.rawValue).png")
            try png(compositing: [img], captions: nil, mode: mode).write(to: url)
            written.append(url.path)
        }
        let sheet = try outDir(lang).appendingPathComponent("_sheet-\(mode.rawValue).png")
        try png(compositing: images, captions: cases.map(\.name), mode: mode).write(to: sheet)
        written.append(sheet.path)
    }
}

// 드롭다운 한도 구획만 렌더: 한도 줄 커스텀 뷰를 쌓아 bitmapImageRep 로 캐시해 PNG 저장
// (build/preview/<언어>/menu-limits-<case>-<light|dark>.png)
@MainActor final class PreviewBackdrop: NSView {
    var color: NSColor = .windowBackgroundColor
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) { color.setFill(); bounds.fill() }
}

/// 메뉴 항목 뷰는 NSMenuItemViewer 안에서 원점이 고정되므로, 행마다 자기 bounds 를 bitmapImageRep 로 캐시한 뒤 배경 위에 합성한다.
@MainActor func stackPNG(_ views: [NSView], mode: Mode) -> Data? {
    guard !views.isEmpty else { return nil }
    let pad: CGFloat = 6
    let width = max(views.map { $0.frame.width }.max() ?? 0, 260) // 실제 메뉴는 다른 항목 때문에 더 넓다
    let rows: [NSBitmapImageRep] = views.map { v in
        v.frame.size.width = width
        let root = PreviewBackdrop(frame: v.bounds) // 행마다 배경을 깔아 투명 배경 위 라벨색 착시를 막는다
        root.color = mode.background
        root.appearance = mode.appearance
        root.addSubview(v)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(width) * scale, pixelsHigh: Int(v.bounds.height) * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = v.bounds.size
        root.cacheDisplay(in: root.bounds, to: rep)
        return rep
    }
    let height = rows.reduce(pad * 2) { $0 + $1.size.height }
    let out = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(width) * scale, pixelsHigh: Int(height) * scale,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    out.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
    mode.background.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    var top = height - pad
    for rep in rows {
        top -= rep.size.height
        rep.draw(in: NSRect(x: 0, y: top, width: rep.size.width, height: rep.size.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return out.representation(using: .png, properties: [:])
}

@MainActor func limitsPNG(_ usage: UsageSnapshot, mode: Mode, lang: Language) -> Data? {
    let menu = MenuBuilder(actions: nil).buildMenu(usage: usage, sessions: counts, auth: .signedIn, now: now, lang: lang)
    return stackPNG(menu.items.prefix { !$0.isSeparatorItem }.compactMap(\.view), mode: mode)
}

let limitCases: [(String, UsageSnapshot)] = [
    ("five-hour-42", UsageSnapshot(
        fiveHour: win(42, in: 2 * h + 13 * 60), weekly: win(63, in: 3 * 86400 + 5 * h), fetchedAt: now)),
    ("five-hour-inactive", fiveHourInactive),
    ("mixed-80s-95s", UsageSnapshot(
        fiveHour: win(96, in: 25 * 60), weekly: win(82, in: 86400 + 3 * h), fable: win(79.9, in: 5 * 86400), fetchedAt: now)),
    ("no-five-hour", noFive),
    ("with-fable", full),
    ("all-100", UsageSnapshot(
        fiveHour: win(100, in: 0), weekly: win(100, in: 3 * 86400), fable: LimitWindow(usedPercent: 1), fetchedAt: now)),
]
for lang in Language.allCases {
    for mode in Mode.allCases {
        for (name, usage) in limitCases {
            guard let data = limitsPNG(usage, mode: mode, lang: lang) else { continue }
            let url = try outDir(lang).appendingPathComponent("menu-limits-\(name)-\(mode.rawValue).png")
            try data.write(to: url)
            written.append(url.path)
        }
    }
}

// 세션 구획: 헤더·`외 N개` 는 커스텀 뷰 행, 세션명은 일반(클릭 가능) 항목이라 기본 글자색(labelColor)으로 그린다.
// 실제 NSMenu 의 항목 글자 위치(14pt)를 가정한 시뮬레이션이다.
// (build/preview/<언어>/menu-sessions-<case>-<light|dark>.png)
@MainActor final class PreviewTextRow: NSView {
    let text: NSAttributedString
    init(title: String) {
        text = NSAttributedString(string: title, attributes: [.foregroundColor: NSColor.labelColor, .font: NSFont.menuFont(ofSize: 0)])
        super.init(frame: NSRect(x: 0, y: 0, width: 14 + ceil(text.size().width) + 14, height: 22))
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        text.draw(at: NSPoint(x: 14, y: ((bounds.height - text.size().height) / 2).rounded()))
    }
}

@MainActor func sessionsPNG(_ s: SessionCounts, mode: Mode, lang: Language) -> Data? {
    let menu = MenuBuilder(actions: nil).buildMenu(usage: nil, sessions: s, auth: .signedOut, now: now, lang: lang)
    // 로그인 안내와 설정 구획 사이: 첫 구분선 다음 ~ 둘째 구분선 앞
    let section = menu.items.drop { !$0.isSeparatorItem }.dropFirst().prefix { !$0.isSeparatorItem }
    return stackPNG(section.map { $0.view ?? PreviewTextRow(title: $0.title) }, mode: mode)
}

func sessionNames(_ prefix: String, _ n: Int) -> [String] { (1...max(n, 1)).prefix(n).map { "\(prefix)\($0)" } }
let longKo = "아주 긴 세션 이름입니다 이것은 사십 자를 훨씬 넘기는 한국어 세션 이름이며 말줄임이 되어야 합니다"
let longEn = "a-very-long-session-name-that-goes-well-beyond-forty-characters-for-sure"
let sessionCases: [(String, SessionCounts)] = [
    ("names", counts),
    ("subagents", SessionCounts(
        active: 5, waiting: 1, idle: 2,
        activeSessions: ["clawdcounter 드롭다운", "맥북 메뉴바 표시 제거", "↳ Session monitor module", "↳ 테스트 작성 및 검증"]
            .map { SessionRef(name: $0, isSubagent: $0.hasPrefix("↳")) }
            + [SessionRef(name: "", isSubagent: true, placeholder: .subagent)],
        waitingSessions: [SessionRef(name: "상태바 앱 이름 추천")],
        idleSessions: ["docs", "refactor-auth"].map { SessionRef(name: $0) })),
    ("over8", SessionCounts(
        active: 12, waiting: 1, idle: 9,
        activeNames: sessionNames("작업 ", 12), waitingNames: ["대기 세션"], idleNames: sessionNames("idle-", 9))),
    ("zero", SessionCounts(active: 0, waiting: 0, idle: 0)),
    ("only-idle", SessionCounts(active: 0, waiting: 0, idle: 2, idleNames: ["a", "b"])),
    ("long-name", SessionCounts(
        active: 2, waiting: 0, idle: 1, activeNames: [longKo, longEn], idleNames: ["짧은 이름"])),
]
for lang in Language.allCases {
    for mode in Mode.allCases {
        for (name, s) in sessionCases {
            let url = try outDir(lang).appendingPathComponent("menu-sessions-\(name)-\(mode.rawValue).png")
            try sessionsPNG(s, mode: mode, lang: lang)?.write(to: url)
            written.append(url.path)
        }
    }
}

// 메뉴 구조 덤프
@MainActor final class NoopActions: MenuActions {
    func login() {}
    func logout() {}
    func quit() {}
    func setRefreshInterval(minutes: Int) {}
    func setLaunchAtLogin(_ enabled: Bool) {}
}
let actions = NoopActions()
let builder = MenuBuilder(actions: actions)
for lang in Language.allCases {
    var dump = ""
    for c in cases {
        let menu = builder.buildMenu(
            usage: c.usage, sessions: c.sessions, auth: c.auth,
            settings: MenuSettings(launchAtLogin: true, refreshMinutes: 2), now: now, lang: lang)
        dump += "## \(c.name)\n\(MenuDump.text(of: menu))\n\n"
    }
    for (name, sessions) in sessionCases {
        let menu = builder.buildMenu(usage: nil, sessions: sessions, auth: .signedOut, now: now, lang: lang)
        dump += "## sessions-\(name)\n\(MenuDump.text(of: menu))\n\n"
    }
    let dumpURL = try outDir(lang).appendingPathComponent("menus.txt")
    try dump.write(to: dumpURL, atomically: true, encoding: .utf8)
    written.append(dumpURL.path)
}
print(written.joined(separator: "\n"))
