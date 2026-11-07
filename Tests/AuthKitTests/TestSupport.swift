import Foundation
@testable import AuthKit

final class StubTransport: HTTPTransport, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    private let handler: Handler

    init(_ handler: @escaping Handler) { self.handler = handler }

    var requests: [URLRequest] { lock.withLock { _requests } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { _requests.append(request) }
        return try await handler(request)
    }

    static func response(_ status: Int, _ json: String, url: URL = OAuthConfig.claudeAI.tokenURL) -> (Data, HTTPURLResponse) {
        (Data(json.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    init(_ now: Date = Date(timeIntervalSince1970: 1_800_000_000)) { _now = now }
    var now: Date { lock.withLock { _now } }
}

final class URLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _urls: [URL] = []
    func append(_ u: URL) { lock.withLock { _urls.append(u) } }
    var urls: [URL] { lock.withLock { _urls } }
}

func jsonBody(_ request: URLRequest) -> [String: String] {
    guard let data = request.httpBody,
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String]
    else { return [:] }
    return obj
}

func queryValue(_ url: URL, _ name: String) -> String? {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
}

/// 리다이렉트를 따라가지 않는 로컬 전용 세션(성공 URL로 실제 네트워크가 나가지 않도록).
final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
    ) async -> URLRequest? { nil }
}

let localSession = URLSession(configuration: .ephemeral, delegate: NoRedirectDelegate(), delegateQueue: nil)

func localGET(_ url: URL) async throws -> HTTPURLResponse {
    let (_, response) = try await localSession.data(from: url)
    return response as! HTTPURLResponse
}
