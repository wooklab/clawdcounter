import XCTest
@testable import AuthKit

final class KeychainTokenStoreTests: XCTestCase {
    func testRoundTrip() throws {
        let store = KeychainTokenStore(service: "ClawdCounter-tests-\(UUID().uuidString)")
        defer { try? store.delete() }
        XCTAssertNil(try store.load())
        let t = StoredTokens(accessToken: "a", refreshToken: "r", expiresAt: Date(timeIntervalSince1970: 1000), scopes: ["s"])
        try store.save(t)
        XCTAssertEqual(try store.load(), t)
        var t2 = t
        t2.accessToken = "b"
        try store.save(t2)
        XCTAssertEqual(try store.load(), t2)
        try store.delete()
        XCTAssertNil(try store.load())
        try store.delete()
    }
}
