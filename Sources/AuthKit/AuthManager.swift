import AppKit
import CoreModels
import Foundation

/// 앱 자체 OAuth(PKCE) 로그인으로 사용량 API용 토큰을 관리한다.
/// Claude Code의 키체인 항목이나 ~/.claude 자격증명은 읽거나 쓰지 않는다.
public actor AuthManager: AuthManaging {
    public typealias URLOpener = @Sendable (URL) async -> Void

    public static let defaultURLOpener: URLOpener = { url in
        await MainActor.run { _ = NSWorkspace.shared.open(url) }
    }

    /// 만료 이 시간 전부터 refresh.
    static let refreshLeeway: TimeInterval = 60

    private let config: OAuthConfig
    private let store: any TokenStore
    private let transport: any HTTPTransport
    private let openURL: URLOpener
    private let now: @Sendable () -> Date
    private let callbackTimeout: TimeInterval
    private nonisolated let broadcaster = Broadcaster<AuthState>(replayLatest: true)

    private var tokens: StoredTokens?
    private var currentState: AuthState
    private var refreshTask: Task<StoredTokens, Error>?
    /// logout마다 증가. 진행 중이던 refresh/login 결과가 logout 이후 반영되지 않게 한다.
    private var generation = 0

    public init(
        config: OAuthConfig = .claudeAI,
        store: any TokenStore = KeychainTokenStore(),
        transport: any HTTPTransport = URLSession.shared,
        openURL: @escaping URLOpener = AuthManager.defaultURLOpener,
        now: @escaping @Sendable () -> Date = { Date() },
        callbackTimeout: TimeInterval = 180
    ) {
        self.config = config
        self.store = store
        self.transport = transport
        self.openURL = openURL
        self.now = now
        self.callbackTimeout = callbackTimeout
        let loaded = (try? store.load()) ?? nil
        self.tokens = loaded
        self.currentState = loaded == nil ? .signedOut : .signedIn
        broadcaster.send(currentState)
    }

    // MARK: - AuthManaging

    public var state: AuthState { currentState }

    public nonisolated func stateStream() -> AsyncStream<AuthState> {
        broadcaster.stream()
    }

    /// 로컬 콜백 서버(127.0.0.1)로 로그인. 서버를 열 수 없으면 `.callbackServerUnavailable`을 던지므로
    /// 호출 측은 `login(manualCodeProvider:)`로 폴백한다.
    public func login() async throws {
        try await runLogin { [config, openURL, callbackTimeout] verifier, state in
            let server = OAuthCallbackServer(
                expectedState: state, callbackPath: config.callbackPath, successURL: config.successURL
            )
            defer { server.stop() }
            let port = try await server.start()
            let redirectURI = "http://localhost:\(port)\(config.callbackPath)"
            let url = Self.makeAuthorizeURL(
                config: config, codeChallenge: PKCE.challenge(for: verifier), state: state, redirectURI: redirectURI
            )
            await openURL(url)
            let callback = try await server.waitForCallback(timeout: callbackTimeout)
            do {
                let tokens = try await self.exchange(
                    code: callback.code, redirectURI: redirectURI, verifier: verifier, state: state
                )
                callback.respond(true)
                return tokens
            } catch {
                callback.respond(false)
                throw error
            }
        }
    }

    /// 수동 폴백: 브라우저에서 로그인 후 사용자가 붙여넣은 `code#state` 문자열로 로그인한다.
    /// - Parameter manualCodeProvider: 인증 URL을 받아(UI 표시용) 사용자가 붙여넣은 문자열을 반환.
    public func login(manualCodeProvider: @escaping @Sendable (URL) async throws -> String) async throws {
        try await runLogin { [config, openURL] verifier, state in
            let redirectURI = config.manualRedirectURL.absoluteString
            let url = Self.makeAuthorizeURL(
                config: config, codeChallenge: PKCE.challenge(for: verifier), state: state, redirectURI: redirectURI
            )
            await openURL(url)
            let pasted = try await manualCodeProvider(url).trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = pasted.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { throw AuthError.invalidManualCode }
            guard parts[1] == state else { throw AuthError.stateMismatch }
            return try await self.exchange(
                code: String(parts[0]), redirectURI: redirectURI, verifier: verifier, state: state
            )
        }
    }

    public func validAccessToken() async throws -> String {
        guard let tokens else {
            throw currentState == .expired ? AuthError.sessionExpired : AuthError.notSignedIn
        }
        if tokens.expiresAt.timeIntervalSince(now()) > Self.refreshLeeway {
            return tokens.accessToken
        }
        let task: Task<StoredTokens, Error>
        if let existing = refreshTask {
            task = existing
        } else {
            let gen = generation
            let refreshToken = tokens.refreshToken
            let scopes = tokens.scopes.isEmpty ? config.scopes : tokens.scopes
            task = Task { try await self.refresh(refreshToken: refreshToken, scopes: scopes, generation: gen) }
            refreshTask = task
        }
        do {
            let refreshed = try await task.value
            if refreshTask == task { refreshTask = nil }
            return refreshed.accessToken
        } catch {
            if refreshTask == task { refreshTask = nil }
            throw error
        }
    }

    public func logout() async {
        generation += 1
        let refreshToken = tokens?.refreshToken
        tokens = nil
        refreshTask?.cancel()
        refreshTask = nil
        try? store.delete()
        setState(.signedOut)
        if let refreshToken { await revoke(refreshToken) }
    }

    // MARK: - 내부

    static func makeAuthorizeURL(config: OAuthConfig, codeChallenge: String, state: String, redirectURI: String) -> URL {
        var comps = URLComponents(url: config.authorizeURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: config.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        // URLComponents는 '+'를 인코딩하지 않으므로 명시적으로 처리.
        comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return comps.url!
    }

    private func runLogin(_ body: (_ verifier: String, _ state: String) async throws -> StoredTokens) async throws {
        guard currentState != .signingIn else { throw AuthError.loginInProgress }
        let previous = currentState
        let gen = generation
        setState(.signingIn)
        do {
            let newTokens = try await body(PKCE.makeVerifier(), PKCE.makeState())
            guard gen == generation else { throw AuthError.cancelled }
            try store.save(newTokens)
            refreshTask = nil
            tokens = newTokens
            setState(.signedIn)
        } catch {
            if gen == generation && currentState == .signingIn { setState(previous) }
            throw error
        }
    }

    private func exchange(code: String, redirectURI: String, verifier: String, state: String) async throws -> StoredTokens {
        let body: [String: String] = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": config.clientID,
            "code_verifier": verifier,
            "state": state,
        ]
        let (data, response) = try await post(config.tokenURL, body: body, timeout: 30)
        guard response.statusCode == 200 else { throw AuthError.tokenExchangeFailed(status: response.statusCode) }
        return try decodeTokens(data, fallbackRefreshToken: nil, fallbackScopes: config.scopes)
    }

    private func refresh(refreshToken: String, scopes: [String], generation gen: Int) async throws -> StoredTokens {
        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": config.clientID,
            "scope": scopes.joined(separator: " "),
        ]
        let (data, response) = try await post(config.tokenURL, body: body, timeout: 30)
        guard gen == generation else { throw AuthError.notSignedIn }
        if response.statusCode != 200 {
            if (response.statusCode == 400 || response.statusCode == 401) && Self.oauthErrorCode(data) == "invalid_grant" {
                tokens = nil
                try? store.delete()
                setState(.expired)
                throw AuthError.sessionExpired
            }
            throw AuthError.refreshFailed(status: response.statusCode)
        }
        let newTokens = try decodeTokens(data, fallbackRefreshToken: refreshToken, fallbackScopes: scopes)
        tokens = newTokens
        try store.save(newTokens)
        return newTokens
    }

    private func revoke(_ refreshToken: String) async {
        let body = ["token": refreshToken, "token_type_hint": "refresh_token", "client_id": config.clientID]
        _ = try? await post(config.revokeURL, body: body, timeout: 5)
    }

    private func post(_ url: URL, body: [String: String], timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            return try await transport.send(request)
        } catch let error as AuthError {
            throw error
        } catch let error as URLError {
            throw error.code == .cancelled ? AuthError.cancelled : AuthError.network(error.code)
        } catch is CancellationError {
            throw AuthError.cancelled
        } catch {
            throw AuthError.network(.unknown)
        }
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Double
        let scope: String?
    }

    private func decodeTokens(_ data: Data, fallbackRefreshToken: String?, fallbackScopes: [String]) throws -> StoredTokens {
        guard let r = try? JSONDecoder().decode(TokenResponse.self, from: data),
              let refreshToken = r.refresh_token ?? fallbackRefreshToken
        else { throw AuthError.invalidResponse }
        let scopes = r.scope.map { $0.split(separator: " ").map(String.init) } ?? fallbackScopes
        return StoredTokens(
            accessToken: r.access_token,
            refreshToken: refreshToken,
            expiresAt: now().addingTimeInterval(r.expires_in),
            scopes: scopes
        )
    }

    /// `{"error":"invalid_grant"}` 또는 `{"error":{"type":"invalid_grant"}}` 모두 처리.
    static func oauthErrorCode(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let s = obj["error"] as? String { return s }
        if let o = obj["error"] as? [String: Any] { return o["type"] as? String }
        return nil
    }

    private func setState(_ newState: AuthState) {
        guard newState != currentState else { return }
        currentState = newState
        broadcaster.send(newState)
    }
}
