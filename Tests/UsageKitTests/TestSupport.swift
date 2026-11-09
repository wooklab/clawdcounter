import CoreModels
import Foundation
@testable import UsageKit

struct StubTokens: TokenProviding {
    var token = "test-token-xyz"
    var error: (any Error)?
    func validAccessToken() async throws -> String {
        if let error { throw error }
        return token
    }
    func invalidate(accessToken: String) async {}
}

/// 401 재시도 검증용: `invalidate` 되면 다음 토큰을 내준다. 토큰이 다 떨어지면 `error` 를 던진다.
final class RotatingTokens: TokenProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [String]
    private var _invalidated: [String] = []
    init(_ tokens: [String]) { queue = tokens }
    var invalidated: [String] { lock.withLock { _invalidated } }
    func validAccessToken() async throws -> String {
        try lock.withLock {
            guard let first = queue.first else { throw URLError(.userAuthenticationRequired) }
            return first
        }
    }
    func invalidate(accessToken: String) async {
        lock.withLock {
            _invalidated.append(accessToken)
            if queue.first == accessToken { queue.removeFirst() }
        }
    }
}

final class StubTransport: UsageTransport, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    private let handler: Handler
    init(_ handler: @escaping Handler) { self.handler = handler }
    var requests: [URLRequest] { lock.withLock { _requests } }
    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { _requests.append(request) }
        return try await handler(request)
    }

    static func response(_ status: Int, _ body: String, headers: [String: String] = [:]) -> (Data, HTTPURLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: UsageClient.endpoint, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }
}

let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

func makeClient(
    tokens: StubTokens = StubTokens(), rawStore: RawResponseStore? = nil,
    _ handler: @escaping StubTransport.Handler
) -> (UsageClient, StubTransport) {
    let transport = StubTransport(handler)
    return (UsageClient(tokens: tokens, transport: transport, rawStore: rawStore, now: { fixedNow }), transport)
}
