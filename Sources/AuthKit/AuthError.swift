import CoreModels
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

    /// 표시 언어로 된 설명. 메인 스레드 밖에서도 읽을 수 있다.
    public var description: String { message() }

    public func message(lang: Language = .current) -> String {
        L10n.tr(key, lang: lang)
    }

    private var key: L10n.Key {
        switch self {
        case .notSignedIn: .authNotSignedIn
        case .sessionExpired: .authSessionExpired
        case .loginInProgress: .authLoginInProgress
        case .cancelled: .authCancelled
        case .timeout: .authTimeout
        case .stateMismatch: .authStateMismatch
        case .invalidManualCode: .authInvalidManualCode
        case .authorizationDenied(let code): .authDenied(code)
        case .callbackServerUnavailable: .authCallbackServerUnavailable
        case .tokenExchangeFailed(let status): .authTokenExchangeFailed(status: status)
        case .refreshFailed(let status): .authRefreshFailed(status: status)
        case .invalidResponse: .authInvalidResponse
        case .network(let code): .networkError(code: code.rawValue)
        case .keychain(let status): .keychainError(status: status)
        }
    }

    static func sanitizedErrorCode(_ raw: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.")
        guard !raw.isEmpty, raw.count <= 64, raw.unicodeScalars.allSatisfy(allowed.contains) else { return "unknown" }
        return raw
    }
}
