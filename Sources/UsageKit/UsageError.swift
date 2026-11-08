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

    public var description: String {
        switch self {
        case .tokenUnavailable: "액세스 토큰을 얻지 못했습니다."
        case .unauthorized: "사용량 조회 인증 실패 (HTTP 401)."
        case .rateLimited(let s): "사용량 조회 한도 초과 (HTTP 429)" + (s.map { ", \(Int($0))초 후 재시도" } ?? "") + "."
        case .http(let status): "사용량 조회 실패 (HTTP \(status))."
        case .network(let code): "네트워크 오류 (\(code.rawValue))."
        case .invalidResponse: "사용량 응답 형식이 올바르지 않습니다."
        }
    }
}
