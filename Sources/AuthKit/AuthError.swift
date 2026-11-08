import Foundation

/// 인증 오류. 토큰·코드·verifier 등 민감값은 절대 담지 않는다.
public enum AuthError: Error, Equatable, Sendable, CustomStringConvertible {
    case notSignedIn
    case sessionExpired
    case loginInProgress
    case cancelled
    case timeout
    case stateMismatch
    case invalidManualCode
    /// OAuth 서버가 콜백으로 돌려준 `error` 코드(예: access_denied). 안전한 문자만 남긴다.
    case authorizationDenied(String)
    case callbackServerUnavailable
    case tokenExchangeFailed(status: Int)
    case refreshFailed(status: Int)
    case invalidResponse
    case network(URLError.Code)
    case keychain(OSStatus)

    public var description: String {
        switch self {
        case .notSignedIn: "로그인되어 있지 않습니다."
        case .sessionExpired: "로그인이 만료되었습니다. 다시 로그인하세요."
        case .loginInProgress: "이미 로그인이 진행 중입니다."
        case .cancelled: "로그인이 취소되었습니다."
        case .timeout: "로그인 대기 시간이 초과되었습니다."
        case .stateMismatch: "로그인 응답 검증(state)에 실패했습니다."
        case .invalidManualCode: "코드 형식이 올바르지 않습니다. 전체 코드를 복사했는지 확인하세요."
        case .authorizationDenied(let code): "로그인이 거부되었습니다 (\(code))."
        case .callbackServerUnavailable: "로컬 콜백 서버를 시작할 수 없습니다."
        case .tokenExchangeFailed(let status): "토큰 교환 실패 (HTTP \(status))."
        case .refreshFailed(let status): "토큰 갱신 실패 (HTTP \(status))."
        case .invalidResponse: "서버 응답 형식이 올바르지 않습니다."
        case .network(let code): "네트워크 오류 (\(code.rawValue))."
        case .keychain(let status): "키체인 오류 (\(status))."
        }
    }

    static func sanitizedErrorCode(_ raw: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.")
        guard !raw.isEmpty, raw.count <= 64, raw.unicodeScalars.allSatisfy(allowed.contains) else { return "unknown" }
        return raw
    }
}
