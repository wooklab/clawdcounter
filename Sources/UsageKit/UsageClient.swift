import CoreModels
import Foundation
import os

/// 테스트에서 스텁할 수 있는 HTTP 전송 계층.
public protocol UsageTransport: Sendable {
    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

extension URLSession: UsageTransport {
    public func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await self.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UsageError.invalidResponse }
        return (data, http)
    }
}

/// `GET https://api.anthropic.com/api/oauth/usage` 호출 -> `UsageSnapshot`.
public struct UsageClient: UsageProviding {
    public static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// 디스크/캐시에 응답을 남기지 않는 기본 세션.
    public static let defaultTransport: any UsageTransport = URLSession(configuration: .ephemeral)

    private let tokens: any TokenProviding
    private let transport: any UsageTransport
    private let rawStore: RawResponseStore?
    private let now: @Sendable () -> Date
    private let log = Logger(subsystem: "clawdcounter", category: "UsageClient")

    public init(
        tokens: any TokenProviding,
        transport: any UsageTransport = UsageClient.defaultTransport,
        rawStore: RawResponseStore? = RawResponseStore(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.tokens = tokens
        self.transport = transport
        self.rawStore = rawStore
        self.now = now
    }

    /// 401 을 받으면 그 토큰을 무효화하고 refresh 한 토큰으로 한 번만 다시 요청한다.
    /// 다시 받은 토큰도 401 이면 세션을 만료시킨다.
    public func fetch() async throws -> UsageSnapshot {
        var (data, response, token) = try await send()
        if response.statusCode == 401 {
            await tokens.invalidate(accessToken: token)
            (data, response, token) = try await send()
        }

        switch response.statusCode {
        case 200..<300: break
        case 401:
            await tokens.reject(accessToken: token)
            throw UsageError.unauthorized
        case 429: throw UsageError.rateLimited(retryAfter: Self.retryAfter(response, now: now()))
        default: throw UsageError.http(status: response.statusCode)
        }

        rawStore?.save(data) // 응답 본문만 저장(토큰/헤더 제외). 디코딩 실패 시에도 남도록 먼저 저장.
        let result = try UsageMapping.map(data, fetchedAt: now())
        if !result.unmappedKeys.isEmpty {
            let keys = result.unmappedKeys.joined(separator: ",")
            log.info("unmapped usage keys: \(keys, privacy: .public)")
        }
        return result.snapshot
    }

    private func send() async throws -> (Data, HTTPURLResponse, token: String) {
        let token: String
        do {
            token = try await tokens.validAccessToken()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw UsageError.tokenUnavailable
        }

        var request = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("ClawdCounter/0.1", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await transport.perform(request)
            return (data, response, token)
        } catch let error as UsageError {
            throw error
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw UsageError.network(error.code)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw UsageError.network(.unknown)
        }
    }

    /// `Retry-After`: 초 또는 HTTP-date. 음수/파싱 실패는 nil.
    static func retryAfter(_ response: HTTPURLResponse, now: Date) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespaces),
              !raw.isEmpty else { return nil }
        if let seconds = TimeInterval(raw) { return seconds >= 0 ? seconds : nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = f.date(from: raw) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }
}
