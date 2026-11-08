import AppKit
import CoreModels
import MenuBarUI

// 상태바 이미지를 케이스 × (light|dark)별 PNG로, 메뉴 구조를 텍스트로 build/preview/ 에 출력한다.
// 실행: swift run --scratch-path .build-ui RenderPreview   (프로젝트 루트에서)

_ = NSApplication.shared

let now = Date(timeIntervalSince1970: 1_800_000_000)
func win(_ pct: Double, in seconds: TimeInterval) -> LimitWindow {
    LimitWindow(usedPercent: pct, resetsAt: now.addingTimeInterval(seconds))
}
let h: TimeInterval = 3600
let counts = SessionCounts(active: 2, waiting: 1, idle: 4)

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

// 실제 응답 형태(Max 5x): 활성 5시간 창 없음, 주간 5%, Fable/크레딧/티켓 없음
let fiveHourInactive = UsageSnapshot(
    fiveHour: LimitWindow(usedPercent: 0, resetsAt: nil), weekly: win(5, in: 6 * 86400 + 4 * h), fetchedAt: now)

let cases: [Case] = [
    Case(name: "five-hour", usage: full, sessions: counts, auth: .signedIn),
    Case(name: "five-hour-inactive", usage: fiveHourInactive, sessions: counts, auth: .signedIn),
    Case(name: "no-five-hour", usage: noFive, sessions: counts, auth: .signedIn),
    Case(name: "no-fable", usage: noFable, sessions: counts, auth: .signedIn),
    Case(name: "sessions-zero", usage: full, sessions: SessionCounts(active: 0, waiting: 0, idle: 0), auth: .signedIn),
    Case(name: "signed-out", usage: nil, sessions: counts, auth: .signedOut),
    Case(name: "expired", usage: full, sessions: counts, auth: .expired),
    Case(name: "high-usage", usage: high, sessions: counts, auth: .signedIn),
    Case(name: "threshold-80", usage: warnOnly, sessions: counts, auth: .signedIn),
    Case(name: "loading", usage: nil, sessions: counts, auth: .signedIn),
    Case(name: "many-sessions", usage: full, sessions: SessionCounts(active: 12, waiting: 10, idle: 25), auth: .signedIn),
    Case(name: "minimal-weekly-only", usage: minimal, sessions: counts, auth: .signedIn),
]

let outDir = URL(fileURLWithPath: "build/preview", isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

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
for mode in Mode.allCases {
    var images: [NSImage] = []
    for c in cases {
        let img = StatusItemRenderer.image(
            usage: c.usage, sessions: c.sessions, auth: c.auth, now: now, appearance: mode.appearance)
        images.append(img)
        let url = outDir.appendingPathComponent("\(c.name)-\(mode.rawValue).png")
        try png(compositing: [img], captions: nil, mode: mode).write(to: url)
        written.append(url.path)
    }
    let sheet = outDir.appendingPathComponent("_sheet-\(mode.rawValue).png")
    try png(compositing: images, captions: cases.map(\.name), mode: mode).write(to: sheet)
    written.append(sheet.path)
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
var dump = ""
for c in cases {
    let menu = builder.buildMenu(
        usage: c.usage, sessions: c.sessions, auth: c.auth,
        settings: MenuSettings(launchAtLogin: true, refreshMinutes: 2), now: now)
    dump += "## \(c.name)\n\(MenuDump.text(of: menu))\n\n"
}
let dumpURL = outDir.appendingPathComponent("menus.txt")
try dump.write(to: dumpURL, atomically: true, encoding: .utf8)
written.append(dumpURL.path)
print(written.joined(separator: "\n"))
