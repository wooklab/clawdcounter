import CoreModels
import Foundation
import MenuBarUI

/// 앱 전체 표시 상태. 상태바 이미지에 영향을 주는 값(usage/counts/authState)이 바뀌면 `onChange`를 호출한다.
@MainActor
final class AppModel {
    static let refreshMinutesKey = "refreshMinutes"

    private let defaults: UserDefaults

    var onChange: (() -> Void)?

    var usage: UsageSnapshot? { didSet { if usage != oldValue { onChange?() } } }
    var counts = SessionCounts(active: 0, waiting: 0, idle: 0) { didSet { if counts != oldValue { onChange?() } } }
    var authState: AuthState = .signedOut { didSet { if authState != oldValue { onChange?() } } }
    /// 마지막 사용량 갱신이 실패한 상태(이전 성공값은 `usage`에 유지). 메뉴에만 표시.
    var usageStale = false

    private(set) var settings: MenuSettings

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.integer(forKey: Self.refreshMinutesKey)
        let minutes = MenuBuilder.refreshIntervalOptions.contains(stored) ? stored : 1
        settings = MenuSettings(launchAtLogin: false, refreshMinutes: minutes)
    }

    func setRefreshMinutes(_ minutes: Int) {
        guard MenuBuilder.refreshIntervalOptions.contains(minutes) else { return }
        settings.refreshMinutes = minutes
        defaults.set(minutes, forKey: Self.refreshMinutesKey)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        settings.launchAtLogin = enabled
    }

    var refreshInterval: TimeInterval { TimeInterval(settings.refreshMinutes * 60) }
}
