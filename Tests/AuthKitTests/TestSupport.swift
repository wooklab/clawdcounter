import Foundation
import Network
import XCTest
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

/// 한 번 열면 모든 대기자가 진행하는 게이트.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock {
                if opened { return true }
                waiters.append(cont)
                return false
            }
            if resumeNow { cont.resume() }
        }
    }

    func open() {
        let all = lock.withLock {
            opened = true
            defer { waiters.removeAll() }
            return waiters
        }
        all.forEach { $0.resume() }
    }
}

/// save가 지정 횟수만큼 실패하는 저장소.
final class FlakySaveStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: StoredTokens?
    private var failuresRemaining: Int
    private var _saveAttempts = 0

    init(_ tokens: StoredTokens?, failSaves: Int) {
        self.tokens = tokens
        self.failuresRemaining = failSaves
    }

    var saveAttempts: Int { lock.withLock { _saveAttempts } }
    var stored: StoredTokens? { lock.withLock { tokens } }

    func load() throws -> StoredTokens? { lock.withLock { tokens } }
    func save(_ t: StoredTokens) throws {
        try lock.withLock {
            _saveAttempts += 1
            if failuresRemaining > 0 {
                failuresRemaining -= 1
                throw AuthError.keychain(errSecInteractionNotAllowed)
            }
            tokens = t
        }
    }
    func delete() throws { lock.withLock { tokens = nil } }
}

func waitUntil(timeout: TimeInterval = 3, _ condition: @Sendable () async -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !(await condition()) {
        guard Date() < deadline else { XCTFail("condition not met in \(timeout)s"); return }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
}

/// 헤더 끝(빈 줄)을 보내지 않은 채로 열어 둔 TCP 연결.
func openPartialRequest(port: UInt16) async throws -> NWConnection {
    let conn = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    conn.start(queue: .global())
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
        conn.send(content: Data("GET /callback HTTP/1.1\r\n".utf8), completion: .contentProcessed { error in
            if let error { cont.resume(throwing: error) } else { cont.resume() }
        })
    }
    return conn
}
