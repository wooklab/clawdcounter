import AppKit
import CoreModels
import Foundation
import os

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
    private static let log = Logger(subsystem: "clawdcounter", category: "AuthManager")

    private var tokens: StoredTokens?
    private var currentState: AuthState
    private var refreshTask: Task<StoredTokens, Error>?
    private var loginTask: Task<StoredTokens, Error>?
    /// logout·로그인 성공마다 증가. 진행 중이던 refresh/login 결과가 그 이후 반영되지 않게 한다.
    private var generation = 0
    /// 로그인 진행 중 refresh가 invalid_grant를 받았는지. 로그인 실패 시 `.expired`로 정리한다.
    private var expiredDuringLogin = false

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
            throw currentState == .expired || expiredDuringLogin ? AuthError.sessionExpired : AuthError.notSignedIn
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

    /// 만료 전이라도 서버가 거부한 토큰은 만료된 것으로 취급한다(메모리만 바꾸고 저장소는 refresh 결과로 갱신된다).
    /// 그 사이 이미 다른 토큰으로 바뀌었으면 아무것도 하지 않는다.
    public func invalidate(accessToken: String) async {
        guard tokens?.accessToken == accessToken else { return }
        tokens?.expiresAt = .distantPast
    }

    /// 진행 중인 refresh/login을 무효화하고 로컬 토큰을 지운 뒤 서버에 revoke를 시도한다.
    /// 참고: refresh 요청이 이미 서버에 도달한 경우 회전된 새 refresh 토큰은 받지 못하므로 revoke되지 않는다.
    public func logout() async {
        generation += 1
        let refreshToken = tokens?.refreshToken
        tokens = nil
        refreshTask?.cancel()
        refreshTask = nil
        loginTask?.cancel()  // 콜백 서버 대기는 취소 핸들러로 즉시 종료된다.
        loginTask = nil
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

    private func runLogin(
        _ body: @escaping @Sendable (_ verifier: String, _ state: String) async throws -> StoredTokens
    ) async throws {
        guard currentState != .signingIn else { throw AuthError.loginInProgress }
        let previous = currentState
        let gen = generation
        expiredDuringLogin = false
        setState(.signingIn)
        let task = Task { try await body(PKCE.makeVerifier(), PKCE.makeState()) }
        loginTask = task
        defer { if loginTask == task { loginTask = nil } }
        do {
            let newTokens = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard gen == generation else { throw AuthError.cancelled }
            try store.save(newTokens)
            // 이전 토큰으로 진행 중인 refresh가 새 토큰을 덮어쓰거나 지우지 못하게 무효화.
            refreshTask?.cancel()
            refreshTask = nil
            generation += 1
            expiredDuringLogin = false
            tokens = newTokens
            setState(.signedIn)
        } catch {
            guard gen == generation else { throw AuthError.cancelled }  // logout으로 취소됨
            if currentState == .signingIn {
                if expiredDuringLogin {
                    expiredDuringLogin = false
                    try? store.delete()
                    setState(.expired)
                } else {
                    setState(previous)
                }
            }
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
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await post(config.tokenURL, body: body, timeout: 30)
        } catch {
            if isSuperseded(generation: gen, refreshToken: refreshToken) { return try currentTokens() }
            throw error
        }
        // 요청 중 logout/새 로그인이 있었으면 이 결과는 버리고 현재 토큰을 돌려준다.
        if isSuperseded(generation: gen, refreshToken: refreshToken) { return try currentTokens() }
        if response.statusCode != 200 {
            if (response.statusCode == 400 || response.statusCode == 401) && Self.oauthErrorCode(data) == "invalid_grant" {
                tokens = nil
                if currentState == .signingIn {
                    // 로그인 진행 중엔 상태/저장소를 건드리지 않는다(중복 로그인 가드 유지). 실패 시 runLogin이 정리.
                    expiredDuringLogin = true
                } else {
                    try? store.delete()
                    setState(.expired)
                }
                throw AuthError.sessionExpired
            }
            throw AuthError.refreshFailed(status: response.statusCode)
        }
        let newTokens = try decodeTokens(data, fallbackRefreshToken: refreshToken, fallbackScopes: scopes)
        tokens = newTokens
        persistRefreshed(newTokens)
        return newTokens
    }

    private func isSuperseded(generation gen: Int, refreshToken: String) -> Bool {
        gen != generation || tokens?.refreshToken != refreshToken
    }

    private func currentTokens() throws -> StoredTokens {
        guard let tokens else { throw AuthError.notSignedIn }
        return tokens
    }

    /// 갱신된 토큰은 이미 메모리에 반영됐으므로 저장 실패는 호출자에게 던지지 않는다(1회 재시도 후 로그만).
    private func persistRefreshed(_ newTokens: StoredTokens) {
        for attempt in 1...2 {
            do {
                try store.save(newTokens)
                return
            } catch {
                let reason = (error as? AuthError)?.description ?? String(describing: type(of: error))
                Self.log.error("갱신 토큰 저장 실패 (시도 \(attempt, privacy: .public)): \(reason, privacy: .public)")
            }
        }
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
