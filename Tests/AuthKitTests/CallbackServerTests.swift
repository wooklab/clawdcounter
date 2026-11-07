import XCTest
@testable import AuthKit

final class CallbackServerTests: XCTestCase {
    private let success = URL(string: "https://example.invalid/success")!

    func testReceivesCodeAndRedirects() async throws {
        let server = OAuthCallbackServer(expectedState: "S1", successURL: success)
        let port = try await server.start()
        let client = Task { try await localGET(URL(string: "http://127.0.0.1:\(port)/callback?code=C1&state=S1")!) }
        let cb = try await server.waitForCallback(timeout: 5)
        XCTAssertEqual(cb.code, "C1")
        cb.respond(true)
        let resp = try await client.value
        XCTAssertEqual(resp.statusCode, 302)
        XCTAssertEqual(resp.value(forHTTPHeaderField: "Location"), success.absoluteString)
        server.stop()
    }

    func testRejectsStateMismatch() async throws {
        let server = OAuthCallbackServer(expectedState: "S1", successURL: success)
        let port = try await server.start()
        let client = Task { try await localGET(URL(string: "http://127.0.0.1:\(port)/callback?code=C1&state=BAD")!) }
        do {
            _ = try await server.waitForCallback(timeout: 5)
            XCTFail("expected stateMismatch")
        } catch {
            XCTAssertEqual(error as? AuthError, .stateMismatch)
        }
        let status = try await client.value.statusCode
        XCTAssertEqual(status, 400)
    }

    func testIgnoresOtherPathsThenAccepts() async throws {
        let server = OAuthCallbackServer(expectedState: "S1", successURL: success)
        let port = try await server.start()
        let r404 = try await localGET(URL(string: "http://127.0.0.1:\(port)/favicon.ico")!)
        XCTAssertEqual(r404.statusCode, 404)
        let client = Task { try await localGET(URL(string: "http://127.0.0.1:\(port)/callback?code=C2&state=S1")!) }
        let cb = try await server.waitForCallback(timeout: 5)
        XCTAssertEqual(cb.code, "C2")
        cb.respond(false)
        let status = try await client.value.statusCode
        XCTAssertEqual(status, 400)
    }

    func testTimeout() async throws {
        let server = OAuthCallbackServer(expectedState: "S1", successURL: success)
        _ = try await server.start()
        do {
            _ = try await server.waitForCallback(timeout: 0.2)
            XCTFail("expected timeout")
        } catch {
            XCTAssertEqual(error as? AuthError, .timeout)
        }
    }

    func testListenerClosedAfterUse() async throws {
        let server = OAuthCallbackServer(expectedState: "S1", successURL: success)
        let port = try await server.start()
        let client = Task { try await localGET(URL(string: "http://127.0.0.1:\(port)/callback?code=C&state=S1")!) }
        let cb = try await server.waitForCallback(timeout: 5)
        cb.respond(true)
        _ = try await client.value
        try await Task.sleep(nanoseconds: 100_000_000)
        do {
            _ = try await localGET(URL(string: "http://127.0.0.1:\(port)/callback?code=C&state=S1")!)
            XCTFail("listener should be closed")
        } catch {}
    }
}
