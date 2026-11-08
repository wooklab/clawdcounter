import AppKit
import CoreModels
import SessionsKit

/// 세션이 도는 앱(Claude 데스크탑 / 터미널 / VS Code 등)을 앞으로 가져온다.
/// 한계: 앱 전면화까지만 한다. 앱 안에서 특정 탭·창·세션을 선택하지는 않는다.
/// tmux 처럼 부모 사슬이 launchd 로 끊기는 경우는 앱을 찾지 못해 beep 만 낸다.
enum SessionActivator {
    static let desktopEntrypoint = "claude-desktop"
    static let desktopBundleID = "com.anthropic.claudefordesktop"

    /// 활성화할 앱을 찾는다(활성화는 하지 않음).
    /// pid 에서 부모를 거슬러 올라가며 `activationPolicy == .regular` 인 첫 앱을 고른다.
    /// 데스크탑 세션은 그 결과가 Claude.app 이어야 하며, 아니면 실행 중인 Claude.app 으로 폴백한다.
    static func resolveApp(for ref: SessionRef) -> NSRunningApplication? {
        let ancestor = ref.focusPid.flatMap { pid in
            ProcessAncestry.firstAncestor(of: pid, parentOf: ProcessAncestry.parentPid(of:), matches: isRegularApp)
        }.flatMap { NSRunningApplication(processIdentifier: $0) }

        guard ref.entrypoint == desktopEntrypoint else { return ancestor }
        if let ancestor, ancestor.bundleIdentifier == desktopBundleID { return ancestor }
        return NSRunningApplication.runningApplications(withBundleIdentifier: desktopBundleID)
            .first { $0.activationPolicy == .regular }
            ?? NSWorkspace.shared.runningApplications.first { $0.activationPolicy == .regular && $0.localizedName == "Claude" }
    }

    /// 앱을 앞으로 가져온다. 못 찾거나 실패하면 beep.
    @MainActor
    static func activate(_ ref: SessionRef) {
        guard let app = resolveApp(for: ref) else {
            NSSound.beep()
            return
        }
        // macOS 14+ 협력 활성화: 메뉴바(accessory) 앱이 활성 앱이 아니어도 요청이 받아들여지도록 양보한다.
        NSApp.yieldActivation(to: app)
        if !app.activate(options: [.activateAllWindows]) { NSSound.beep() }
    }

    private static func isRegularApp(_ pid: Int32) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular
    }
}
