import AppKit
import CoreModels

// 진단: `ClawdCounter --probe-focus <pid> [entrypoint]` — 활성화 대상 앱만 찾아 출력하고 종료한다(앞으로 가져오지 않음).
if let i = CommandLine.arguments.firstIndex(of: "--probe-focus") {
    let rest = CommandLine.arguments.dropFirst(i + 1)
    guard let pid = rest.first.flatMap({ Int32($0) }) else {
        print("usage: ClawdCounter --probe-focus <pid> [entrypoint]")
        exit(2)
    }
    let ref = SessionRef(name: "probe", pid: pid, entrypoint: rest.dropFirst().first)
    if let app = SessionActivator.resolveApp(for: ref) {
        print("bundleID=\(app.bundleIdentifier ?? "nil") name=\(app.localizedName ?? "nil") pid=\(app.processIdentifier)")
    } else {
        print("not found")
    }
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
