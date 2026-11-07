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

    func testWrongOrMissingStateIsRejectedButKeepsWaiting() async throws {
        let server = OAuthCallbackServer(expectedState: "S1", successURL: success)
        defer { server.stop() }
        let port = try await server.start()
        let bad = try await localGET(URL(string: "http://127.0.0.1:\(port)/callback?code=EVIL&state=BAD")!)
        XCTAssertEqual(bad.statusCode, 400)
        let missing = try await localGET(URL(string: "http://127.0.0.1:\(port)/callback?code=EVIL")!)
        XCTAssertEqual(missing.statusCode, 400)
        let deniedWrongState = try await localGET(URL(string: "http://127.0.0.1:\(port)/callback?error=access_denied&state=BAD")!)
        XCTAssertEqual(deniedWrongState.statusCode, 400)
        let client = Task { try await localGET(URL(string: "http://127.0.0.1:\(port)/callback?code=GOOD&state=S1")!) }
        let cb = try await server.waitForCallback(timeout: 5)
        XCTAssertEqual(cb.code, "GOOD")
        cb.respond(true)
        let status = try await client.value.statusCode
        XCTAssertEqual(status, 302)
    }

    func testErrorWithMatchingStateFails() async throws {
        let server = OAuthCallbackServer(expectedState: "S1", successURL: success)
        defer { server.stop() }
        let port = try await server.start()
        let client = Task { try await localGET(URL(string: "http://127.0.0.1:\(port)/callback?error=access_denied&state=S1")!) }
        do {
            _ = try await server.waitForCallback(timeout: 5)
            XCTFail("expected authorizationDenied")
        } catch {
            XCTAssertEqual(error as? AuthError, .authorizationDenied("access_denied"))
        }
        let status = try await client.value.statusCode
        XCTAssertEqual(status, 400)
    }

    func testIdleConnectionTimesOut() async throws {
        let server = OAuthCallbackServer(expectedState: "S1", successURL: success, connectionTimeout: 0.3)
        defer { server.stop() }
        let port = try await server.start()
        let client = try await openPartialRequest(port: port)
        defer { client.cancel() }
        try await waitUntil { server.openConnectionCount == 1 }
        try await waitUntil { server.openConnectionCount == 0 }
    }

    func testStopCancelsOpenConnections() async throws {
        let server = OAuthCallbackServer(expectedState: "S1", successURL: success)
        let port = try await server.start()
        let client = try await openPartialRequest(port: port)
        defer { client.cancel() }
        try await waitUntil { server.openConnectionCount == 1 }
        server.stop()
        try await waitUntil { server.openConnectionCount == 0 }
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
