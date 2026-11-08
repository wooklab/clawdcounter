import AppKit
import CoreModels

/// 메뉴 클릭 동작. 실제 동작 연결은 통합 단계에서 한다.
@MainActor
public protocol MenuActions: AnyObject {
    func login()
    func logout()
    func quit()
    func openSettings()
    /// 세션명 항목 클릭: 그 세션이 도는 앱을 앞으로 가져온다.
    func focusSession(_ ref: SessionRef)
}

extension MenuActions {
    /// 설정 창이 없는 소비자(RenderPreview 등)용 기본 구현.
    public func openSettings() {}
    /// 세션 활성화가 없는 소비자(RenderPreview 등)용 기본 구현.
    public func focusSession(_ ref: SessionRef) {}
}

/// 앱이 보관하는 설정 값. 메뉴 구성에는 쓰이지 않는다(설정 창이 직접 다룸).
public struct MenuSettings: Equatable, Sendable {
    public var launchAtLogin: Bool
    public var refreshMinutes: Int
    public init(launchAtLogin: Bool = false, refreshMinutes: Int = 1) {
        self.launchAtLogin = launchAtLogin
        self.refreshMinutes = refreshMinutes
    }
}

/// 드롭다운 NSMenu 빌더. 상태가 바뀔 때마다 `buildMenu`로 새 메뉴를 만든다.
/// 항목의 action target(`MenuTarget`)은 `representedObject`로도 강하게 붙들려
/// 빌더를 따로 보관하지 않아도 메뉴가 살아 있는 동안 클릭이 전달된다. `actions`는 weak.
@MainActor
public final class MenuBuilder {
    public static let refreshIntervalOptions = [1, 2, 5]

    private weak var actions: MenuActions?

    public init(actions: MenuActions?) {
        self.actions = actions
    }

    public func buildMenu(
        usage: UsageSnapshot?,
        sessions: SessionCounts,
        auth: AuthState,
        settings: MenuSettings = MenuSettings(), // 호환용: 메뉴 구성에 쓰이지 않음
        now: Date = Date(),
        lang: Language = .current
    ) -> NSMenu {
        let target = MenuTarget(actions: actions)
        var sections: [[NSMenuItem]] = []
        sections.append(usageSection(usage: usage, auth: auth, now: now, lang: lang))
        sections.append(creditSection(usage: usage, auth: auth, lang: lang))
        sections.append(ticketSection(usage: usage, auth: auth, lang: lang))
        sections.append(sessionSection(sessions, lang: lang))
        sections.append(settingsSection(auth: auth, target: target, lang: lang))
        sections.append([actionItem(L10n.tr(.quit, lang: lang), key: "q", target: target, action: #selector(MenuTarget.quit))])

        let menu = NSMenu()
        menu.autoenablesItems = false
        for section in sections where !section.isEmpty {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            section.forEach(menu.addItem)
        }
        return menu
    }

    // MARK: - 구획

    private func usageSection(usage: UsageSnapshot?, auth: AuthState, now: Date, lang: Language) -> [NSMenuItem] {
        switch auth {
        case .signedOut: return [infoItem(L10n.tr(.menuLoginRequired, lang: lang))]
        case .expired: return [infoItem(L10n.tr(.menuLoginExpired, lang: lang))]
        case .signingIn: return [infoItem(L10n.tr(.loggingIn, lang: lang))]
        case .signedIn: break
        }
        guard let usage else { return [infoItem(L10n.tr(.loadingUsage, lang: lang))] }
        var rows: [LimitRowContent] = []
        if let w = usage.fiveHour {
            rows.append(LimitRowContent(
                label: L10n.tr(.limitFiveHour, lang: lang), window: w, now: now,
                noResetNote: L10n.tr(.noActiveWindow, lang: lang), lang: lang))
        }
        if let w = usage.weekly { rows.append(LimitRowContent(label: L10n.tr(.limitWeekly, lang: lang), window: w, now: now, lang: lang)) }
        if let w = usage.fable { rows.append(LimitRowContent(label: L10n.tr(.limitFable, lang: lang), window: w, now: now, lang: lang)) }
        let columns = LimitColumns.fitting(rows)
        return rows.map { limitItem($0, columns: columns) }
    }

    private func creditSection(usage: UsageSnapshot?, auth: AuthState, lang: Language) -> [NSMenuItem] {
        guard auth == .signedIn, let c = usage?.credit else { return [] }
        let text = Self.creditText(c, lang: lang)
        let item = infoItem(text)
        item.setAccessibilityLabel(text)
        return [item]
    }

    /// 총량 있음: `크레딧 $12.50 / $100.00`(비활성이면 뒤에 ` (사용 불가)`).
    /// 총량 없음: 활성 `크레딧 $12.50 사용`, 비활성 `크레딧 $0.00 (추가 사용 꺼짐)`.
    static func creditText(_ c: CreditUsage, lang: Language = .current) -> String {
        let used = money(c.used, unit: c.unit)
        if let total = c.total {
            return L10n.tr(.creditWithTotal(used: used, total: money(total, unit: c.unit)), lang: lang)
                + (c.isEnabled ? "" : L10n.tr(.creditUnavailableSuffix, lang: lang))
        }
        return L10n.tr(c.isEnabled ? .creditUsed(used) : .creditExtraOff(used), lang: lang)
    }

    /// USD 는 `$12.50`, 그 외 통화는 `12.50 EUR`, 통화 없으면 `12.50`.
    static func money(_ v: Double, unit: String?) -> String {
        let n = number(v)
        guard let unit, !unit.isEmpty else { return n }
        return unit.uppercased() == "USD" ? "$\(n)" : "\(n) \(unit)"
    }

    private func ticketSection(usage: UsageSnapshot?, auth: AuthState, lang: Language) -> [NSMenuItem] {
        guard auth == .signedIn, let t = usage?.resetTickets else { return [] }
        return [infoItem(L10n.tr(.resetTickets(t.remaining), lang: lang))]
    }

    private func sessionSection(_ s: SessionCounts, lang: Language) -> [NSMenuItem] {
        Self.sessionItems(s, actions: actions, lang: lang)
    }

    private func settingsSection(auth: AuthState, target: MenuTarget, lang: Language) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        switch auth {
        case .signedOut:
            items.append(actionItem(L10n.tr(.login, lang: lang), target: target, action: #selector(MenuTarget.login)))
        case .expired:
            items.append(actionItem(L10n.tr(.loginAgain, lang: lang), target: target, action: #selector(MenuTarget.login)))
        case .signingIn:
            let item = actionItem(L10n.tr(.loggingIn, lang: lang), target: target, action: #selector(MenuTarget.login))
            item.isEnabled = false
            items.append(item)
        case .signedIn:
            items.append(actionItem(L10n.tr(.logout, lang: lang), target: target, action: #selector(MenuTarget.logout)))
        }
        items.append(actionItem(L10n.tr(.settingsEllipsis, lang: lang), target: target, action: #selector(MenuTarget.openSettings)))
        return items
    }

    // MARK: - 항목 헬퍼

    static func number(_ v: Double) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }

    private func infoItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.foregroundColor: NSColor.labelColor, .font: NSFont.menuFont(ofSize: 0)]
        )
        return item
    }

    /// 한도 줄: 커스텀 뷰 행. title/접근성에는 평문을 넣어 MenuDump·테스트·VoiceOver 가 읽는다.
    private func limitItem(_ row: LimitRowContent, columns: LimitColumns) -> NSMenuItem {
        let item = NSMenuItem(title: row.plainText, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.view = LimitRowView(content: row, columns: columns)
        item.setAccessibilityLabel(row.accessibilityText)
        return item
    }

    /// 상태별 최대 나열 개수 / 세션명 최대 글자 수.
    static let maxNamesPerState = 8
    static let maxNameLength = 40
    static let nameIndent = "    "

    /// 세션 구획: 상태마다 헤더 줄(`● 활성 2`) + 세션명 줄(`    · 이름`, 최대 8개, 초과 시 `    외 N개`).
    /// 세 헤더는 개수가 0 이어도 항상 표시한다.
    /// 헤더·`외 N개` 는 비클릭 커스텀 뷰 행(labelColor), 세션명은 클릭 가능한 일반 항목(`focusSession` 호출).
    /// 모든 항목의 `title` 은 평문이다.
    static func sessionItems(_ s: SessionCounts, actions: MenuActions? = nil, lang: Language = .current) -> [NSMenuItem] {
        let groups: [(dot: String, color: NSColor, label: String, count: Int, sessions: [SessionRef])] = [
            ("●", .systemGreen, L10n.tr(.sessionActive, lang: lang), s.active, s.activeSessions),
            ("●", .systemYellow, L10n.tr(.sessionWaiting, lang: lang), s.waiting, s.waitingSessions),
            ("○", .labelColor, L10n.tr(.sessionIdle, lang: lang), s.idle, s.idleSessions),
        ]
        var items: [NSMenuItem] = []
        for g in groups {
            items.append(textRow(
                "\(g.dot) \(g.label) \(g.count)", dotColor: g.color,
                accessibility: L10n.tr(.sessionCountSpoken(state: g.label, count: g.count), lang: lang)))
            for ref in g.sessions.prefix(maxNamesPerState) {
                let shown = displayName(sessionName(ref, lang: lang))
                let target = SessionTarget(ref: ref, actions: actions)
                let item = NSMenuItem(title: "\(nameIndent)· \(shown)", action: #selector(SessionTarget.focus), keyEquivalent: "")
                item.target = target
                item.representedObject = target // target은 weak이므로 강한 참조 유지
                item.isEnabled = true
                item.setAccessibilityLabel(L10n.tr(.openSession(shown), lang: lang))
                items.append(item)
            }
            let extra = g.sessions.count - maxNamesPerState
            if extra > 0 {
                items.append(textRow(
                    nameIndent + L10n.tr(.moreCount(extra), lang: lang), dotColor: nil,
                    accessibility: L10n.tr(.moreSessionsSpoken(state: g.label, count: extra), lang: lang)))
            }
        }
        return items
    }

    /// 세션명. 대체 표시명(`placeholder`)이면 `lang` 언어 문자열.
    static func sessionName(_ ref: SessionRef, lang: Language = .current) -> String {
        switch ref.placeholder {
        case nil: ref.name
        case .unnamed: L10n.tr(.unnamedSession, lang: lang)
        case .subagent: L10n.tr(.unnamedSubagent, lang: lang)
        }
    }

    /// 줄바꿈·탭은 공백으로, 40자 초과는 39자 + `…`.
    static func displayName(_ name: String) -> String {
        let flat = String(name.map { $0.isNewline || $0 == "\t" ? " " : $0 })
        guard flat.count > maxNameLength else { return flat }
        return String(flat.prefix(maxNameLength - 1)) + "…"
    }

    /// 비클릭 커스텀 뷰 행. title/접근성에는 평문을 넣어 MenuDump·테스트·VoiceOver 가 읽는다.
    private static func textRow(_ title: String, dotColor: NSColor?, accessibility: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.view = SessionRowView(text: title, dotColor: dotColor, accessibilityText: accessibility)
        item.setAccessibilityLabel(accessibility)
        return item
    }

    private func actionItem(_ title: String, key: String = "", target: MenuTarget, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target
        item.representedObject = target // target은 weak이므로 강한 참조 유지
        item.isEnabled = true
        return item
    }
}

/// 클릭 대상. 메뉴 항목의 `representedObject`로 강하게 유지된다.
@MainActor
final class MenuTarget: NSObject {
    weak var actions: MenuActions?
    init(actions: MenuActions?) { self.actions = actions }

    @objc func login() { actions?.login() }
    @objc func logout() { actions?.logout() }
    @objc func quit() { actions?.quit() }
    @objc func openSettings() { actions?.openSettings() }
}

/// 세션명 항목 클릭 대상. 항목의 `representedObject` 로 강하게 유지된다.
@MainActor
final class SessionTarget: NSObject {
    weak var actions: MenuActions?
    let ref: SessionRef
    init(ref: SessionRef, actions: MenuActions?) {
        self.ref = ref
        self.actions = actions
    }

    @objc func focus() { actions?.focusSession(ref) }
}

/// 메뉴 구조 텍스트 덤프(디버그/테스트용). 구분선은 "---", 서브메뉴는 2칸 들여쓰기, 체크는 "[x] ".
@MainActor
public enum MenuDump {
    public static func text(of menu: NSMenu, indent: Int = 0) -> String {
        let pad = String(repeating: "  ", count: indent)
        var lines: [String] = []
        for item in menu.items {
            if item.isSeparatorItem { lines.append("\(pad)---"); continue }
            var line = pad
            if item.state == .on { line += "[x] " }
            line += item.title
            if !item.isEnabled { line += "  (disabled)" }
            lines.append(line)
            if let sub = item.submenu { lines.append(text(of: sub, indent: indent + 1)) }
        }
        return lines.joined(separator: "\n")
    }
}
