import AppKit
import MenuBarUI
import ServiceManagement
import os

/// 설정 창(로그인 시 자동 실행, 사용량 갱신 주기). 창은 한 번만 만들고 닫아도 해제하지 않아 재오픈에 재사용한다.
@MainActor
final class SettingsWindowController: NSObject {
    private let log = Logger(subsystem: "clawdcounter", category: "Settings")
    private let model: AppModel
    private let onRefreshIntervalChanged: () -> Void

    let window: NSWindow
    private let launchCheckbox = NSButton(checkboxWithTitle: "로그인 시 자동 실행", target: nil, action: nil)
    private let messageLabel = NSTextField(labelWithString: "")
    private let intervalPopup = NSPopUpButton(frame: .zero, pullsDown: false)

    init(model: AppModel, onRefreshIntervalChanged: @escaping () -> Void) {
        self.model = model
        self.onRefreshIntervalChanged = onRefreshIntervalChanged
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 200),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        super.init()

        window.title = "ClawdCounter 설정"
        window.isReleasedWhenClosed = false
        buildContent()
        syncControls()
    }

    /// 창을 앞으로 가져온다(이미 열려 있으면 그대로 앞으로). 열 때마다 실제 상태를 다시 읽는다.
    func present() {
        syncControls()
        if !window.isVisible { window.center() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - 구성

    private func buildContent() {
        let content = window.contentView!

        launchCheckbox.target = self
        launchCheckbox.action = #selector(launchAtLoginToggled)
        launchCheckbox.frame = NSRect(x: 24, y: 140, width: 312, height: 20)

        messageLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        messageLabel.textColor = .systemRed
        messageLabel.lineBreakMode = .byTruncatingTail
        messageLabel.frame = NSRect(x: 42, y: 118, width: 294, height: 16)

        let intervalLabel = NSTextField(labelWithString: "사용량 갱신 주기")
        intervalLabel.frame = NSRect(x: 24, y: 76, width: 140, height: 20)

        for minutes in MenuBuilder.refreshIntervalOptions {
            intervalPopup.addItem(withTitle: "\(minutes)분")
            intervalPopup.lastItem?.tag = minutes
        }
        intervalPopup.target = self
        intervalPopup.action = #selector(intervalChanged)
        intervalPopup.frame = NSRect(x: 236, y: 72, width: 100, height: 26)

        [launchCheckbox, messageLabel, intervalLabel, intervalPopup].forEach(content.addSubview)
    }

    private func syncControls() {
        launchCheckbox.state = SMAppService.mainApp.status == .enabled ? .on : .off
        intervalPopup.selectItem(withTag: model.settings.refreshMinutes)
    }

    // MARK: - 동작

    @objc private func launchAtLoginToggled() {
        let enable = launchCheckbox.state == .on
        messageLabel.stringValue = ""
        do {
            if enable { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            log.error("launch at login change failed: \(error.localizedDescription, privacy: .public)")
            messageLabel.stringValue = "자동 실행 설정에 실패했습니다"
        }
        if enable, SMAppService.mainApp.status == .requiresApproval {
            messageLabel.stringValue = "시스템 설정의 로그인 항목에서 승인이 필요합니다"
        }
        launchCheckbox.state = SMAppService.mainApp.status == .enabled ? .on : .off // 실제 상태로 되돌림
    }

    @objc private func intervalChanged() {
        model.setRefreshMinutes(intervalPopup.selectedTag())
        onRefreshIntervalChanged()
    }
}
