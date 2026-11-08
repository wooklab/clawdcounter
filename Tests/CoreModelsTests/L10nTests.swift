import CoreModels
import XCTest

final class L10nTests: XCTestCase {
    func testResolveMatchesSystemLanguages() {
        XCTAssertEqual(Language.resolve(["ja-JP"]), .ja)
        XCTAssertEqual(Language.resolve(["zh-Hans-CN"]), .zhHans)
        XCTAssertEqual(Language.resolve(["zh-CN"]), .zhHans)
        XCTAssertEqual(Language.resolve(["fr-FR"]), .en)
        XCTAssertEqual(Language.resolve(["ko-KR", "en-US"]), .ko)
        XCTAssertEqual(Language.resolve(["en-GB"]), .en)
        XCTAssertEqual(Language.resolve([]), .en)
        // 지원하지 않는 언어는 건너뛰고 다음 선호 언어를 본다.
        XCTAssertEqual(Language.resolve(["fr-FR", "ja-JP"]), .ja)
        // 번체 중국어는 간체로 보지 않는다.
        XCTAssertEqual(Language.resolve(["zh-Hant-TW"]), .en)
        XCTAssertEqual(Language.resolve(["zh-TW", "ko"]), .ko)
        XCTAssertEqual(Language.resolve(["zh_HK"]), .en)
    }

    func testPreferenceRoundTripAndResolution() {
        for p in LanguagePreference.allCases {
            XCTAssertEqual(LanguagePreference(rawValue: p.rawValue), p)
        }
        XCTAssertEqual(LanguagePreference.allCases.map(\.rawValue), ["system", "ko", "en", "zh-Hans", "ja"])
        XCTAssertNil(LanguagePreference(rawValue: "fr"))
        XCTAssertEqual(LanguagePreference.system.resolved(preferred: ["ja-JP"]), .ja)
        XCTAssertEqual(LanguagePreference.language(.ko).resolved(preferred: ["ja-JP"]), .ko)
    }

    func testPreferenceStorage() throws {
        let suite = "L10nTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(LanguagePreference.load(from: defaults), .system) // 기본값은 시스템 설정
        LanguagePreference.language(.zhHans).save(to: defaults)
        XCTAssertEqual(LanguagePreference.load(from: defaults), .language(.zhHans))
        defaults.set("bogus", forKey: LanguagePreference.defaultsKey)
        XCTAssertEqual(LanguagePreference.load(from: defaults), .system)
    }

    func testLanguageNamesAreNativeInEveryLanguage() {
        for lang in Language.allCases {
            XCTAssertEqual(LanguagePreference.allCases.dropFirst().map { $0.displayName(lang: lang) },
                           ["한국어", "English", "简体中文", "日本語"])
        }
        XCTAssertEqual(Language.allCases.map { LanguagePreference.system.displayName(lang: $0) },
                       ["시스템 설정", "System default", "跟随系统", "システム設定に従う"])
    }

    /// 용어집 핵심 문자열.
    func testGlossaryStrings() {
        func all(_ key: L10n.Key) -> [String] { Language.allCases.map { L10n.tr(key, lang: $0) } }
        XCTAssertEqual(all(.statusLoginRequired), ["로그인 필요", "Login required", "需要登录", "ログインが必要"])
        XCTAssertEqual(all(.statusLoginAgain), ["다시 로그인 필요", "Log in again", "需要重新登录", "再ログインが必要"])
        XCTAssertEqual(all(.moreCount(3)), ["외 3개", "+3 more", "另外 3 个", "他 3 件"])
        XCTAssertEqual(all(.sessionActive), ["활성", "Active", "活跃", "アクティブ"])
        XCTAssertEqual(all(.sessionWaiting), ["응답대기", "Waiting", "等待响应", "応答待ち"])
        XCTAssertEqual(all(.sessionIdle), ["비활성", "Idle", "空闲", "非アクティブ"])
        XCTAssertEqual(all(.login), ["Claude 로그인", "Log in to Claude", "登录 Claude", "Claude にログイン"])
        XCTAssertEqual(all(.logout), ["Claude 로그아웃", "Log out of Claude", "退出 Claude 登录", "Claude からログアウト"])
        XCTAssertEqual(all(.launchAtLogin), ["로그인 시 자동 실행", "Launch at login", "登录时自动启动", "ログイン時に自動起動"])
        XCTAssertEqual(all(.refreshInterval), ["사용량 갱신 주기", "Usage refresh interval", "用量刷新间隔", "使用量の更新間隔"])
        XCTAssertEqual(all(.language), ["언어", "Language", "语言", "言語"])
        XCTAssertEqual(all(.quit), ["종료", "Quit", "退出", "終了"])
        XCTAssertEqual(all(.hoursMinutes(3, 20)), ["3시간 20분", "3h 20m", "3 小时 20 分", "3時間20分"])
    }
}
