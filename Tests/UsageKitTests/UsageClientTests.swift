import CoreModels
import XCTest
@testable import UsageKit

private let okBody = #"{"seven_day": {"utilization": 42, "resets_at": 1800003600}, "mystery": 1}"#

final class UsageClientTests: XCTestCase {
    func testRequestShapeAndSnapshot() async throws {
        let (client, transport) = makeClient { _ in StubTransport.response(200, okBody) }
        let snap = try await client.fetch()
        XCTAssertEqual(snap.weekly?.usedPercent, 42)
        XCTAssertEqual(snap.fetchedAt, fixedNow)

        let req = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(req.httpMethod, "GET")
        XCTAssertEqual(req.url?.absoluteString, "https://api.anthropic.com/api/oauth/usage")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer test-token-xyz")
        XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
        XCTAssertEqual(req.value(forHTTPHeaderField: "User-Agent"), "ClawdCounter/0.1")
    }

    func testUnauthorized() async {
        let (client, transport) = makeClient { _ in StubTransport.response(401, #"{"error":"bearer test-token-xyz"}"#) }
        await assertThrows(client, .unauthorized)
        XCTAssertEqual(transport.requests.count, 2, "401 이면 한 번만 다시 시도한다")
    }

    func testUnauthorizedRetriesOnceWithRefreshedToken() async throws {
        let tokens = RotatingTokens(["AT_OLD", "AT_NEW"])
        let transport = StubTransport { req in
            req.value(forHTTPHeaderField: "Authorization") == "Bearer AT_NEW"
                ? StubTransport.response(200, okBody) : StubTransport.response(401, "{}")
        }
        let client = UsageClient(tokens: tokens, transport: transport, rawStore: nil, now: { fixedNow })
        let snap = try await client.fetch()
        XCTAssertEqual(snap.weekly?.usedPercent, 42)
        XCTAssertEqual(tokens.invalidated, ["AT_OLD"])
        XCTAssertEqual(tokens.rejected, [])
        XCTAssertEqual(transport.requests.map { $0.value(forHTTPHeaderField: "Authorization") },
                       ["Bearer AT_OLD", "Bearer AT_NEW"])
    }

    func testUnauthorizedAfterRefreshRejectsNewToken() async {
        let tokens = RotatingTokens(["AT_OLD", "AT_NEW"])
        let transport = StubTransport { _ in StubTransport.response(401, "{}") }
        let client = UsageClient(tokens: tokens, transport: transport, rawStore: nil, now: { fixedNow })
        await assertThrows(client, .unauthorized)
        XCTAssertEqual(tokens.invalidated, ["AT_OLD"])
        XCTAssertEqual(tokens.rejected, ["AT_NEW"])
    }

    func testUnauthorizedThenTokenUnavailable() async {
        let tokens = RotatingTokens(["AT_OLD"])
        let transport = StubTransport { _ in StubTransport.response(401, "{}") }
        let client = UsageClient(tokens: tokens, transport: transport, rawStore: nil, now: { fixedNow })
        do { _ = try await client.fetch(); XCTFail("expected tokenUnavailable") } catch {
            XCTAssertEqual(error as? UsageError, .tokenUnavailable)
        }
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testRateLimitedWithRetryAfterSeconds() async {
        let (client, _) = makeClient { _ in StubTransport.response(429, "{}", headers: ["Retry-After": "120"]) }
        await assertThrows(client, .rateLimited(retryAfter: 120))
    }

    func testRateLimitedWithRetryAfterHTTPDate() async {
        // fixedNow = 2027-01-15 08:00:00 GMT
        let (client, _) = makeClient { _ in
            StubTransport.response(429, "{}", headers: ["Retry-After": "Fri, 15 Jan 2027 08:01:30 GMT"])
        }
        await assertThrows(client, .rateLimited(retryAfter: 90))
    }

    func testRateLimitedWithoutHeader() async {
        let (client, _) = makeClient { _ in StubTransport.response(429, "{}") }
        await assertThrows(client, .rateLimited(retryAfter: nil))
    }

    func testOtherStatus() async {
        let (client, _) = makeClient { _ in StubTransport.response(503, "oops") }
        await assertThrows(client, .http(status: 503))
    }

    func testNetworkError() async {
        let (client, _) = makeClient { _ in throw URLError(.notConnectedToInternet) }
        await assertThrows(client, .network(.notConnectedToInternet))
    }

    func testTokenFailureMapsToTokenUnavailable() async {
        struct Boom: Error {}
        let (client, transport) = makeClient(tokens: StubTokens(error: Boom())) { _ in StubTransport.response(200, "{}") }
        await assertThrows(client, .tokenUnavailable)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testInvalidBody() async {
        let (client, _) = makeClient { _ in StubTransport.response(200, "<html>") }
        await assertThrows(client, .invalidResponse)
    }

    func testErrorDescriptionsDoNotLeakToken() {
        let errors: [UsageError] = [.tokenUnavailable, .unauthorized, .rateLimited(retryAfter: 5), .http(status: 500), .network(.timedOut), .invalidResponse]
        for e in errors { XCTAssertFalse(e.description.contains("test-token")) }
    }

    func testRawResponseSavedWith0600AndNoToken() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("usagekit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("sub/last_usage_raw.json")
        let (client, _) = makeClient(rawStore: RawResponseStore(fileURL: file)) { _ in StubTransport.response(200, okBody) }

        _ = try await client.fetch()
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), okBody)
        let perms = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)

        // 덮어쓰기
        let (client2, _) = makeClient(rawStore: RawResponseStore(fileURL: file)) { _ in StubTransport.response(200, "{}") }
        _ = try await client2.fetch()
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "{}")
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("test-token"))
    }

    func testRawResponseNotSavedOnError() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("usagekit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("last_usage_raw.json")
        let (client, _) = makeClient(rawStore: RawResponseStore(fileURL: file)) { _ in StubTransport.response(401, "{}") }
        _ = try? await client.fetch()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    private func assertThrows(_ client: UsageClient, _ expected: UsageError, line: UInt = #line) async {
        do {
            _ = try await client.fetch()
            XCTFail("expected \(expected)", line: line)
        } catch {
            XCTAssertEqual(error as? UsageError, expected, line: line)
        }
    }
}
