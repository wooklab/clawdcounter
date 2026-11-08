import CoreModels
import Foundation

/// 사용량 조회 오류. 토큰·헤더·응답 본문 등 민감값은 담지 않는다.
public enum UsageError: Error, Equatable, Sendable, CustomStringConvertible {
    /// 액세스 토큰을 얻지 못함(미로그인/만료/갱신 실패). 상세는 AuthManager 상태를 본다.
    case tokenUnavailable
    /// HTTP 401.
    case unauthorized
    /// HTTP 429. `retryAfter`는 `Retry-After` 헤더(초). 없으면 nil.
    case rateLimited(retryAfter: TimeInterval?)
    case http(status: Int)
    case network(URLError.Code)
    /// 응답이 JSON 객체가 아님.
    case invalidResponse

    public var retryAfter: TimeInterval? {
        if case .rateLimited(let s) = self { return s }
        return nil
    }

    /// 표시 언어로 된 설명. 메인 스레드 밖에서도 읽을 수 있다.
    public var description: String { message() }

    public func message(lang: Language = .current) -> String {
        L10n.tr(key, lang: lang)
    }

    private var key: L10n.Key {
        switch self {
        case .tokenUnavailable: .usageTokenUnavailable
        case .unauthorized: .usageUnauthorized
        case .rateLimited(let s): .usageRateLimited(retryAfterSeconds: s.map { Int($0) })
        case .http(let status): .usageHTTP(status: status)
        case .network(let code): .networkError(code: code.rawValue)
        case .invalidResponse: .usageInvalidResponse
        }
    }
}
