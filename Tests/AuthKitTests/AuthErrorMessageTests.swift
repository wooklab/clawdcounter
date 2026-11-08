import CoreModels
import XCTest
@testable import AuthKit

final class AuthErrorMessageTests: XCTestCase {
    func testMessagesPerLanguage() {
        XCTAssertEqual(AuthError.tokenExchangeFailed(status: 400).message(lang: .ko), "토큰 교환 실패 (HTTP 400).")
        XCTAssertEqual(AuthError.tokenExchangeFailed(status: 400).message(lang: .en), "Token exchange failed (HTTP 400).")
        XCTAssertEqual(AuthError.cancelled.message(lang: .zhHans), "登录已取消。")
        XCTAssertEqual(AuthError.timeout.message(lang: .ja), "ログインの待機時間を超えました。")
    }
}
