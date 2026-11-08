import AppKit
import CoreModels
import MenuBarUI
import ServiceManagement
import os

/// 설정 창(로그인 시 자동 실행, 사용량 갱신 주기, 언어). 창은 한 번만 만들고 닫아도 해제하지 않아 재오픈에 재사용한다.
@MainActor
final class SettingsWindowController: NSObject {
    private let log = Logger(subsystem: "clawdcounter", category: "Settings")
    private let model: AppModel
    private let onRefreshIntervalChanged: () -> Void

    let window: NSWindow
    private let launchCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let messageLabel = NSTextField(labelWithString: "")
    /// 언어를 바꿨을 때 다시 그릴 수 있도록 문구 대신 키를 보관한다.
    private var message: L10n.Key? { didSet { messageLabel.stringValue = message.map { L10n.tr($0) } ?? "" } }
    private let intervalLabel = NSTextField(labelWithString: "")
    private let intervalPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let languageLabel = NSTextField(labelWithString: "")
    private let languagePopup = NSPopUpButton(frame: .zero, pullsDown: false)

    init(model: AppModel, onRefreshIntervalChanged: @escaping () -> Void) {
        self.model = model
        self.onRefreshIntervalChanged = onRefreshIntervalChanged
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 200),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        super.init()

        window.isReleasedWhenClosed = false
        buildContent()
        applyTexts()
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

        intervalLabel.frame = NSRect(x: 24, y: 76, width: 200, height: 20)

        for minutes in MenuBuilder.refreshIntervalOptions {
            intervalPopup.addItem(withTitle: "")
            intervalPopup.lastItem?.tag = minutes
        }
        intervalPopup.target = self
        intervalPopup.action = #selector(intervalChanged)
        intervalPopup.frame = NSRect(x: 236, y: 72, width: 100, height: 26)

        languageLabel.frame = NSRect(x: 24, y: 36, width: 150, height: 20)
        for (i, _) in LanguagePreference.allCases.enumerated() {
            languagePopup.addItem(withTitle: "")
            languagePopup.lastItem?.tag = i
        }
        languagePopup.target = self
        languagePopup.action = #selector(languageChanged)
        languagePopup.frame = NSRect(x: 176, y: 32, width: 160, height: 26)

        [launchCheckbox, messageLabel, intervalLabel, intervalPopup, languageLabel, languagePopup].forEach(content.addSubview)
    }

    /// 현재 언어로 모든 라벨을 다시 쓴다(언어 변경 시 즉시 호출).
    private func applyTexts() {
        window.title = L10n.tr(.settingsTitle)
        launchCheckbox.title = L10n.tr(.launchAtLogin)
        intervalLabel.stringValue = L10n.tr(.refreshInterval)
        for item in intervalPopup.itemArray { item.title = L10n.tr(.refreshMinutesOption(item.tag)) }
        languageLabel.stringValue = L10n.tr(.language)
        for (i, pref) in LanguagePreference.allCases.enumerated() { languagePopup.item(at: i)?.title = pref.displayName() }
        messageLabel.stringValue = message.map { L10n.tr($0) } ?? ""
    }

    private func syncControls() {
        launchCheckbox.state = SMAppService.mainApp.status == .enabled ? .on : .off
        intervalPopup.selectItem(withTag: model.settings.refreshMinutes)
        languagePopup.selectItem(withTag: LanguagePreference.allCases.firstIndex(of: model.languagePreference) ?? 0)
    }

    // MARK: - 동작

    @objc private func launchAtLoginToggled() {
        let enable = launchCheckbox.state == .on
        message = nil
        do {
            if enable { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            log.error("launch at login change failed: \(error.localizedDescription, privacy: .public)")
            message = .launchAtLoginFailed
        }
        if enable, SMAppService.mainApp.status == .requiresApproval {
            message = .loginItemApprovalRequired
        }
        launchCheckbox.state = SMAppService.mainApp.status == .enabled ? .on : .off // 실제 상태로 되돌림
    }

    @objc private func intervalChanged() {
        model.setRefreshMinutes(intervalPopup.selectedTag())
        onRefreshIntervalChanged()
    }

    @objc private func languageChanged() {
        let index = languagePopup.selectedTag()
        guard LanguagePreference.allCases.indices.contains(index) else { return }
        model.setLanguagePreference(LanguagePreference.allCases[index]) // 상태바는 model.onChange 로 다시 그려진다
        applyTexts()
    }
}
