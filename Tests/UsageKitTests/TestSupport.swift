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
