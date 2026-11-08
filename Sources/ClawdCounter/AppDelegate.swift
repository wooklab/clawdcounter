import AppKit
import AuthKit
import CoreModels
import MenuBarUI
import SessionsKit
import UsageKit
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, MenuActions {
    private let log = Logger(subsystem: "clawdcounter", category: "App")

    private let model = AppModel()
    private let sessions = SessionMonitor()
    private let auth = AuthManager()
    private var poller: UsagePoller!
    private lazy var menuBuilder = MenuBuilder(actions: self)
    private lazy var settingsWindow = SettingsWindowController(
        model: model, onRefreshIntervalChanged: { [weak self] in self?.poller.reschedule() }
    )

    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var appearanceObservation: NSKeyValueObservation?
    private var backgroundTasks: [Task<Void, Never>] = []
    private var loginTask: Task<Void, Never>?
    private var probePending = CommandLine.arguments.contains("--probe-usage")

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.onChange = { [weak self] in self?.render() }

        poller = UsagePoller(
            client: UsageClient(tokens: auth),
            interval: { [weak self] in self?.model.refreshInterval ?? 60 },
            onSuccess: { [weak self] snapshot in
                self?.model.usageStale = false
                self?.model.usage = snapshot
            },
            onFailure: { [weak self] in self?.model.usageStale = true }
        )

        menu.autoenablesItems = false
        menu.delegate = self
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.menu = menu
        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            appearanceObservation = button.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.render() }
            }
        }
        render()

        let authStream = auth.stateStream()
        backgroundTasks.append(Task { [weak self] in
            for await state in authStream { self?.handleAuth(state) }
        })

        let countsStream = sessions.countsStream()
        sessions.start()
        backgroundTasks.append(Task { [weak self] in
            for await counts in countsStream { self?.model.counts = counts }
        })

        // 남은 시간 표기가 시간에 따라 변하므로 주기적으로 다시 그린다.
        backgroundTasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                self?.render()
            }
        })
    }

    func applicationWillTerminate(_ notification: Notification) {
        backgroundTasks.forEach { $0.cancel() }
        loginTask?.cancel()
        poller?.stop()
        sessions.stop()
    }

    // MARK: - 상태 반영

    private func handleAuth(_ state: AuthState) {
        model.authState = state
        if state == .signedIn {
            if probePending {
                probePending = false
                let probe = UsageProbe(tokens: auth)
                backgroundTasks.append(Task { await probe.run() })
            }
            if !poller.isRunning { poller.start(immediate: true) }
        } else {
            poller.stop()
            model.usage = nil
            model.usageStale = false
        }
    }

    private func render() {
        guard let button = statusItem?.button else { return }
        button.image = StatusItemRenderer.image(
            usage: model.usage, sessions: model.counts, auth: model.authState,
            appearance: button.effectiveAppearance
        )
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        let built = menuBuilder.buildMenu(
            usage: model.usage, sessions: model.counts, auth: model.authState
        )
        var items = built.items
        built.removeAllItems() // 항목은 한 메뉴에만 속할 수 있다.

        if model.usageStale && model.authState == .signedIn {
            let failure = NSMenuItem(
                title: model.usage == nil ? "사용량 갱신 실패" : "마지막 갱신 실패 · 이전 값 표시",
                action: nil, keyEquivalent: ""
            )
            failure.isEnabled = false
            failure.attributedTitle = NSAttributedString(
                string: failure.title,
                attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.menuFont(ofSize: 0)]
            )
            // 한도 구획(첫 구분선 앞) 끝에 붙인다.
            items.insert(failure, at: items.firstIndex(where: \.isSeparatorItem) ?? items.endIndex)
        }

        menu.removeAllItems()
        items.forEach(menu.addItem)
        poller.refreshNow()
    }

    // MARK: - MenuActions

    func login() {
        guard loginTask == nil else { return }
        loginTask = Task { [weak self] in
            await self?.runLogin()
            self?.loginTask = nil
        }
    }

    private func runLogin() async {
        do {
            do {
                try await auth.login()
            } catch AuthError.callbackServerUnavailable {
                log.info("callback server unavailable; falling back to manual code entry")
                try await auth.login(manualCodeProvider: { [weak self] _ in
                    guard let self else { throw AuthError.cancelled }
                    return try await self.askManualCode()
                })
            }
        } catch AuthError.cancelled {
            // 사용자 취소/로그아웃으로 인한 중단: 알림 없음
        } catch is CancellationError {
        } catch let error as AuthError {
            log.error("login failed: \(error.description, privacy: .public)")
            ManualCodePrompt.showFailure(error)
        } catch {
            log.error("login failed with unexpected error")
        }
    }

    private func askManualCode() throws -> String {
        try ManualCodePrompt.ask()
    }

    func logout() {
        loginTask?.cancel()
        Task { [auth] in await auth.logout() }
    }

    func quit() {
        NSApp.terminate(nil)
    }

    func openSettings() {
        settingsWindow.present()
    }
}
