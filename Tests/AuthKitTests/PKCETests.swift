import XCTest
@testable import AuthKit

final class PKCETests: XCTestCase {
    func testRFC7636AppendixBVector() {
        XCTAssertEqual(
            PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        )
    }

    func testVerifierFormat() {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let v = PKCE.makeVerifier()
        XCTAssertTrue((43...128).contains(v.count))
        XCTAssertTrue(v.unicodeScalars.allSatisfy(allowed.contains))
        XCTAssertNotEqual(v, PKCE.makeVerifier())
        let c = PKCE.challenge(for: v)
        XCTAssertEqual(c.count, 43)
        XCTAssertFalse(c.contains("=") || c.contains("+") || c.contains("/"))
    }

    func testAuthorizeURLParameters() {
        let url = AuthManager.makeAuthorizeURL(
            config: .claudeAI, codeChallenge: "CH", state: "ST", redirectURI: "http://localhost:1234/callback"
        )
        XCTAssertTrue(url.absoluteString.hasPrefix("https://claude.com/cai/oauth/authorize?code=true&"))
        XCTAssertEqual(queryValue(url, "client_id"), "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
        XCTAssertEqual(queryValue(url, "response_type"), "code")
        XCTAssertEqual(queryValue(url, "redirect_uri"), "http://localhost:1234/callback")
        XCTAssertEqual(queryValue(url, "scope"), "user:profile user:inference")
        XCTAssertEqual(queryValue(url, "code_challenge"), "CH")
        XCTAssertEqual(queryValue(url, "code_challenge_method"), "S256")
        XCTAssertEqual(queryValue(url, "state"), "ST")
        XCTAssertTrue(url.absoluteString.contains("scope=user:profile%20user:inference"))
    }
}
