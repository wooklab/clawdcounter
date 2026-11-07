import Foundation

/// OAuth 엔드포인트/클라이언트 설정. 값은 Claude Code 바이너리에서 확인한 비공식 정보다.
public struct OAuthConfig: Sendable, Equatable {
    public var clientID: String
    public var authorizeURL: URL
    public var tokenURL: URL
    public var revokeURL: URL
    public var manualRedirectURL: URL
    public var successURL: URL
    public var scopes: [String]
    public var callbackPath: String

    public init(
        clientID: String,
        authorizeURL: URL,
        tokenURL: URL,
        revokeURL: URL,
        manualRedirectURL: URL,
        successURL: URL,
        scopes: [String],
        callbackPath: String = "/callback"
    ) {
        self.clientID = clientID
        self.authorizeURL = authorizeURL
        self.tokenURL = tokenURL
        self.revokeURL = revokeURL
        self.manualRedirectURL = manualRedirectURL
        self.successURL = successURL
        self.scopes = scopes
        self.callbackPath = callbackPath
    }

    /// claude.ai 계정 로그인 기본값.
    public static let claudeAI = OAuthConfig(
        clientID: "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
        authorizeURL: URL(string: "https://claude.com/cai/oauth/authorize")!,
        tokenURL: URL(string: "https://platform.claude.com/v1/oauth/token")!,
        revokeURL: URL(string: "https://platform.claude.com/v1/oauth/token/revoke")!,
        manualRedirectURL: URL(string: "https://platform.claude.com/oauth/code/callback")!,
        successURL: URL(string: "https://platform.claude.com/oauth/code/success?app=claude-code")!,
        scopes: ["user:profile", "user:inference"]
    )
}
