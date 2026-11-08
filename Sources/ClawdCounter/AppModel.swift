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
    /// 표시 언어 설정. 실제 언어는 `Language.current` 에 반영되어 UI·오류 설명이 읽는다.
    private(set) var languagePreference: LanguagePreference

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.integer(forKey: Self.refreshMinutesKey)
        let minutes = MenuBuilder.refreshIntervalOptions.contains(stored) ? stored : 1
        settings = MenuSettings(launchAtLogin: false, refreshMinutes: minutes)
        languagePreference = LanguagePreference.load(from: defaults)
        Language.setCurrent(languagePreference.resolved())
    }

    /// 언어 설정을 저장하고 현재 언어를 바꾼다. 상태바 다시 그리기는 `onChange` 로 알린다.
    func setLanguagePreference(_ preference: LanguagePreference) {
        guard preference != languagePreference else { return }
        languagePreference = preference
        preference.save(to: defaults)
        Language.setCurrent(preference.resolved())
        onChange?()
    }

    func setRefreshMinutes(_ minutes: Int) {
        guard MenuBuilder.refreshIntervalOptions.contains(minutes) else { return }
        settings.refreshMinutes = minutes
        defaults.set(minutes, forKey: Self.refreshMinutesKey)
    }

    var refreshInterval: TimeInterval { TimeInterval(settings.refreshMinutes * 60) }
}
