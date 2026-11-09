import CoreModels
import XCTest
@testable import AuthKit

final class AuthManagerTests: XCTestCase {
    private let tokenJSON = #"{"access_token":"AT_NEW","refresh_token":"RT_NEW","expires_in":3600,"scope":"user:profile user:inference"}"#

    private func storedTokens(expiresIn: TimeInterval, clock: TestClock) -> StoredTokens {
        StoredTokens(accessToken: "AT_OLD", refreshToken: "RT_OLD",
                     expiresAt: clock.now.addingTimeInterval(expiresIn), scopes: ["user:profile", "user:inference"])
    }

    private func makeManager(
        store: InMemoryTokenStore, transport: StubTransport, clock: TestClock = TestClock(),
        opener: @escaping AuthManager.URLOpener = { _ in }
    ) -> AuthManager {
        AuthManager(store: store, transport: transport, openURL: opener, now: { clock.now }, callbackTimeout: 5)
    }

    // MARK: login

    func testManualLoginExchangesCode() async throws {
        let store = InMemoryTokenStore()
        let transport = StubTransport { [tokenJSON] _ in StubTransport.response(200, tokenJSON) }
        let opened = URLBox()
        let m = makeManager(store: store, transport: transport, opener: { opened.append($0) })

        try await m.login(manualCodeProvider: { url in "THE_CODE#\(queryValue(url, "state")!)" })

        let state = await m.state
        XCTAssertEqual(state, .signedIn)
        let authURL = try XCTUnwrap(opened.urls.first)
        XCTAssertEqual(queryValue(authURL, "redirect_uri"), "https://platform.claude.com/oauth/code/callback")
        let req = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(req.url, OAuthConfig.claudeAI.tokenURL)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = jsonBody(req)
        XCTAssertEqual(body["grant_type"], "authorization_code")
        XCTAssertEqual(body["code"], "THE_CODE")
        XCTAssertEqual(body["redirect_uri"], "https://platform.claude.com/oauth/code/callback")
        XCTAssertEqual(body["client_id"], OAuthConfig.claudeAI.clientID)
        XCTAssertEqual(body["state"], queryValue(authURL, "state"))
        XCTAssertEqual(PKCE.challenge(for: try XCTUnwrap(body["code_verifier"])), queryValue(authURL, "code_challenge"))
        XCTAssertEqual(try store.load()?.accessToken, "AT_NEW")
        XCTAssertEqual(try store.load()?.refreshToken, "RT_NEW")
    }

    func testManualLoginRejectsStateMismatch() async throws {
        let store = InMemoryTokenStore()
        let transport = StubTransport { [tokenJSON] _ in StubTransport.response(200, tokenJSON) }
        let m = makeManager(store: store, transport: transport)
        do {
            try await m.login(manualCodeProvider: { _ in "CODE#wrong-state" })
            XCTFail("expected stateMismatch")
        } catch {
            XCTAssertEqual(error as? AuthError, .stateMismatch)
        }
        let state = await m.state
        XCTAssertEqual(state, .signedOut)
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertNil(try store.load())
    }

    func testManualLoginRejectsMalformedCode() async throws {
        let m = makeManager(store: InMemoryTokenStore(), transport: StubTransport { _ in throw URLError(.badURL) })
        do {
            try await m.login(manualCodeProvider: { _ in "no-hash" })
            XCTFail("expected invalidManualCode")
        } catch {
            XCTAssertEqual(error as? AuthError, .invalidManualCode)
        }
    }

    func testLoginViaCallbackServer() async throws {
        let store = InMemoryTokenStore()
        let transport = StubTransport { [tokenJSON] _ in StubTransport.response(200, tokenJSON) }
        let responses = URLBox()
        let m = makeManager(store: store, transport: transport, opener: { url in
            let redirect = URL(string: queryValue(url, "redirect_uri")!)!
            XCTAssertEqual(redirect.host, "localhost")
            var comps = URLComponents(url: redirect, resolvingAgainstBaseURL: false)!
            comps.host = "127.0.0.1"
            comps.queryItems = [URLQueryItem(name: "code", value: "CB_CODE"),
                                URLQueryItem(name: "state", value: queryValue(url, "state"))]
            let target = comps.url!
            Task {
                if let r = try? await localGET(target) { responses.append(URL(string: "status:\(r.statusCode)")!) }
            }
        })
        try await m.login()
        let state = await m.state
        XCTAssertEqual(state, .signedIn)
        let body = jsonBody(try XCTUnwrap(transport.requests.first))
        XCTAssertEqual(body["code"], "CB_CODE")
        XCTAssertTrue(body["redirect_uri"]!.hasPrefix("http://localhost:"))
        XCTAssertTrue(body["redirect_uri"]!.hasSuffix("/callback"))
        XCTAssertEqual(try store.load()?.accessToken, "AT_NEW")
        for _ in 0..<50 where responses.urls.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(responses.urls.first?.absoluteString, "status:302")
    }

    // MARK: refresh

    func testFreshTokenReturnedWithoutRefresh() async throws {
        let clock = TestClock()
        let transport = StubTransport { _ in XCTFail("no network"); throw URLError(.badURL) }
        let m = makeManager(store: InMemoryTokenStore(storedTokens(expiresIn: 3600, clock: clock)),
                            transport: transport, clock: clock)
        let token = try await m.validAccessToken()
        XCTAssertEqual(token, "AT_OLD")
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testRefreshWhenNearExpiryPersistsRotatedToken() async throws {
        let clock = TestClock()
        let store = InMemoryTokenStore(storedTokens(expiresIn: 30, clock: clock))
        let transport = StubTransport { [tokenJSON] _ in StubTransport.response(200, tokenJSON) }
        let m = makeManager(store: store, transport: transport, clock: clock)

        let token = try await m.validAccessToken()
        XCTAssertEqual(token, "AT_NEW")
        let body = jsonBody(try XCTUnwrap(transport.requests.first))
        XCTAssertEqual(body["grant_type"], "refresh_token")
        XCTAssertEqual(body["refresh_token"], "RT_OLD")
        XCTAssertEqual(body["client_id"], OAuthConfig.claudeAI.clientID)
        XCTAssertEqual(body["scope"], "user:profile user:inference")
        let saved = try XCTUnwrap(store.load())
        XCTAssertEqual(saved.refreshToken, "RT_NEW")
        XCTAssertEqual(saved.expiresAt, clock.now.addingTimeInterval(3600))
    }

    func testInvalidateForcesRefreshBeforeExpiry() async throws {
        let clock = TestClock()
        let store = InMemoryTokenStore(storedTokens(expiresIn: 3600, clock: clock))
        let transport = StubTransport { [tokenJSON] _ in StubTransport.response(200, tokenJSON) }
        let m = makeManager(store: store, transport: transport, clock: clock)

        await m.invalidate(accessToken: "AT_OLD")
        let token = try await m.validAccessToken()
        XCTAssertEqual(token, "AT_NEW")
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(try store.load()?.accessToken, "AT_NEW")
    }

    func testInvalidateIgnoresOtherToken() async throws {
        let clock = TestClock()
        let transport = StubTransport { _ in XCTFail("no network"); throw URLError(.badURL) }
        let m = makeManager(store: InMemoryTokenStore(storedTokens(expiresIn: 3600, clock: clock)),
                            transport: transport, clock: clock)
        await m.invalidate(accessToken: "AT_SOMETHING_ELSE")
        let token = try await m.validAccessToken()
        XCTAssertEqual(token, "AT_OLD")
    }

    func testRefreshKeepsOldRefreshTokenWhenNotRotated() async throws {
        let clock = TestClock()
        let store = InMemoryTokenStore(storedTokens(expiresIn: 0, clock: clock))
        let transport = StubTransport { _ in StubTransport.response(200, #"{"access_token":"AT2","expires_in":60}"#) }
        let m = makeManager(store: store, transport: transport, clock: clock)
        _ = try await m.validAccessToken()
        XCTAssertEqual(try store.load()?.refreshToken, "RT_OLD")
        XCTAssertEqual(try store.load()?.scopes, ["user:profile", "user:inference"])
    }

    func testConcurrentCallsRefreshOnce() async throws {
        let clock = TestClock()
        let store = InMemoryTokenStore(storedTokens(expiresIn: 10, clock: clock))
        let transport = StubTransport { [tokenJSON] _ in
            try await Task.sleep(nanoseconds: 200_000_000)
            return StubTransport.response(200, tokenJSON)
        }
        let m = makeManager(store: store, transport: transport, clock: clock)
        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<10 { group.addTask { try await m.validAccessToken() } }
            var all: [String] = []
            for try await t in group { all.append(t) }
            return all
        }
        XCTAssertEqual(tokens.count, 10)
        XCTAssertTrue(tokens.allSatisfy { $0 == "AT_NEW" })
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(try store.load()?.refreshToken, "RT_NEW")
    }

    func testInvalidGrantExpiresSession() async throws {
        let clock = TestClock()
        let store = InMemoryTokenStore(storedTokens(expiresIn: 0, clock: clock))
        let transport = StubTransport { _ in
            StubTransport.response(400, #"{"error":{"type":"invalid_grant","message":"x"}}"#)
        }
        let m = makeManager(store: store, transport: transport, clock: clock)
        // Broadcaster는 bufferingNewest(1)이므로 replay 값을 먼저 소비해야 다음 값이 덮어쓰지 않는다.
        var states = m.stateStream().makeAsyncIterator()
        let first = await states.next()
        XCTAssertEqual(first, .signedIn)
        do {
            _ = try await m.validAccessToken()
            XCTFail("expected sessionExpired")
        } catch {
            XCTAssertEqual(error as? AuthError, .sessionExpired)
        }
        let state = await m.state
        XCTAssertEqual(state, .expired)
        XCTAssertNil(try store.load())
        let second = await states.next()
        XCTAssertEqual(second, .expired)
        do { _ = try await m.validAccessToken(); XCTFail() } catch {
            XCTAssertEqual(error as? AuthError, .sessionExpired)
        }
    }

    func testInvalidGrantStringFormAlsoExpires() async throws {
        let clock = TestClock()
        let store = InMemoryTokenStore(storedTokens(expiresIn: 0, clock: clock))
        let transport = StubTransport { _ in StubTransport.response(401, #"{"error":"invalid_grant"}"#) }
        let m = makeManager(store: store, transport: transport, clock: clock)
        _ = try? await m.validAccessToken()
        let state = await m.state
        XCTAssertEqual(state, .expired)
    }

    func testTransientErrorKeepsSession() async throws {
        let clock = TestClock()
        let store = InMemoryTokenStore(storedTokens(expiresIn: 0, clock: clock))
        let transport = StubTransport { _ in throw URLError(.notConnectedToInternet) }
        let m = makeManager(store: store, transport: transport, clock: clock)
        do {
            _ = try await m.validAccessToken()
            XCTFail("expected network error")
        } catch {
            XCTAssertEqual(error as? AuthError, .network(.notConnectedToInternet))
        }
        let state = await m.state
        XCTAssertEqual(state, .signedIn)
        XCTAssertEqual(try store.load()?.refreshToken, "RT_OLD")
    }

    func testServerErrorKeepsSession() async throws {
        let clock = TestClock()
        let store = InMemoryTokenStore(storedTokens(expiresIn: 0, clock: clock))
        let transport = StubTransport { _ in StubTransport.response(500, "{}") }
        let m = makeManager(store: store, transport: transport, clock: clock)
        do { _ = try await m.validAccessToken(); XCTFail() } catch {
            XCTAssertEqual(error as? AuthError, .refreshFailed(status: 500))
        }
        XCTAssertNotNil(try store.load())
    }

    // MARK: logout / state

    func testLogoutClearsStoreAndRevokes() async throws {
        let clock = TestClock()
        let store = InMemoryTokenStore(storedTokens(expiresIn: 3600, clock: clock))
        let transport = StubTransport { _ in StubTransport.response(200, "{}") }
        let m = makeManager(store: store, transport: transport, clock: clock)
        await m.logout()
        XCTAssertNil(try store.load())
        let state = await m.state
        XCTAssertEqual(state, .signedOut)
        let req = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(req.url?.absoluteString, "https://platform.claude.com/v1/oauth/token/revoke")
        XCTAssertEqual(jsonBody(req)["token_type_hint"], "refresh_token")
        do { _ = try await m.validAccessToken(); XCTFail() } catch {
            XCTAssertEqual(error as? AuthError, .notSignedIn)
        }
    }

    func testLogoutSucceedsLocallyWhenRevokeFails() async throws {
        let clock = TestClock()
        let store = InMemoryTokenStore(storedTokens(expiresIn: 3600, clock: clock))
        let m = makeManager(store: store, transport: StubTransport { _ in throw URLError(.timedOut) }, clock: clock)
        await m.logout()
        XCTAssertNil(try store.load())
        let state = await m.state
        XCTAssertEqual(state, .signedOut)
    }

    func testInitialStateFromStore() async throws {
        let clock = TestClock()
        let signedIn = makeManager(store: InMemoryTokenStore(storedTokens(expiresIn: 3600, clock: clock)),
                                   transport: StubTransport { _ in throw URLError(.badURL) })
        var it = signedIn.stateStream().makeAsyncIterator()
        let first = await it.next()
        XCTAssertEqual(first, .signedIn)
        let signedOut = makeManager(store: InMemoryTokenStore(), transport: StubTransport { _ in throw URLError(.badURL) })
        let s = await signedOut.state
        XCTAssertEqual(s, .signedOut)
    }

    func testTokenDescriptionsRedacted() {
        let t = StoredTokens(accessToken: "SECRET_AT", refreshToken: "SECRET_RT", expiresAt: Date(), scopes: [])
        XCTAssertFalse("\(t)".contains("SECRET"))
        XCTAssertFalse(String(reflecting: t).contains("SECRET"))
    }

    // MARK: 로그인/refresh 경합 (리뷰 #1)

    private let tokenJSON_B = #"{"access_token":"AT_B","refresh_token":"RT_B","expires_in":3600}"#

    private static func manualCode(_ url: URL) -> String { "CODE#\(queryValue(url, "state")!)" }

    func testLoginDuringRefreshIsNotOverwrittenByStaleRefresh() async throws {
        let clock = TestClock()
        let store = InMemoryTokenStore(storedTokens(expiresIn: 0, clock: clock))
        let gate = Gate()
        let transport = StubTransport { [tokenJSON_B] req in
            if jsonBody(req)["grant_type"] == "refresh_token" {
                await gate.wait()
                return StubTransport.response(200, #"{"access_token":"AT_A2","refresh_token":"RT_A2","expires_in":3600}"#)
            }
            return StubTransport.response(200, tokenJSON_B)
        }
        let m = makeManager(store: store, transport: transport, clock: clock)
        let refreshing = Task { try await m.validAccessToken() }
        try await waitUntil { transport.requests.count == 1 }
        try await m.login(manualCodeProvider: { Self.manualCode($0) })
        gate.open()
        let token = try await refreshing.value
        XCTAssertEqual(token, "AT_B")
        XCTAssertEqual(try store.load()?.refreshToken, "RT_B")
        let state = await m.state
        XCTAssertEqual(state, .signedIn)
        let again = try await m.validAccessToken()
        XCTAssertEqual(again, "AT_B")
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testStaleInvalidGrantAfterLoginDoesNotExpireNewSession() async throws {
        let clock = TestClock()
        let store = InMemoryTokenStore(storedTokens(expiresIn: 0, clock: clock))
        let gate = Gate()
        let transport = StubTransport { [tokenJSON_B] req in
            if jsonBody(req)["grant_type"] == "refresh_token" {
                await gate.wait()
                return StubTransport.response(400, #"{"error":"invalid_grant"}"#)
            }
            return StubTransport.response(200, tokenJSON_B)
        }
        let m = makeManager(store: store, transport: transport, clock: clock)
        let refreshing = Task { try await m.validAccessToken() }
        try await waitUntil { transport.requests.count == 1 }
        try await m.login(manualCodeProvider: { Self.manualCode($0) })
        gate.open()
        let token = try await refreshing.value
        XCTAssertEqual(token, "AT_B")
        let state = await m.state
        XCTAssertEqual(state, .signedIn)
        XCTAssertEqual(try store.load()?.refreshToken, "RT_B")
    }

    func testInvalidGrantDuringLoginKeepsSigningInGuard() async throws {
        let clock = TestClock()
        let store = InMemoryTokenStore(storedTokens(expiresIn: 0, clock: clock))
        let refreshGate = Gate(), loginGate = Gate()
        let transport = StubTransport { [tokenJSON_B] req in
            if jsonBody(req)["grant_type"] == "refresh_token" {
                await refreshGate.wait()
                return StubTransport.response(400, #"{"error":"invalid_grant"}"#)
            }
            return StubTransport.response(200, tokenJSON_B)
        }
        let m = makeManager(store: store, transport: transport, clock: clock)
        let refreshing = Task { try await m.validAccessToken() }
        try await waitUntil { transport.requests.count == 1 }
        let login = Task {
            try await m.login(manualCodeProvider: { url in await loginGate.wait(); return Self.manualCode(url) })
        }
        try await waitUntil { await m.state == .signingIn }
        refreshGate.open()
        do { _ = try await refreshing.value; XCTFail("expected sessionExpired") } catch {
            XCTAssertEqual(error as? AuthError, .sessionExpired)
        }
        let during = await m.state
        XCTAssertEqual(during, .signingIn)
        XCTAssertEqual(try store.load()?.refreshToken, "RT_OLD")
        do { try await m.login(manualCodeProvider: { Self.manualCode($0) }); XCTFail("expected loginInProgress") } catch {
            XCTAssertEqual(error as? AuthError, .loginInProgress)
        }
        loginGate.open()
        try await login.value
        let after = await m.state
        XCTAssertEqual(after, .signedIn)
        XCTAssertEqual(try store.load()?.refreshToken, "RT_B")
    }

    func testInvalidGrantDuringFailedLoginEndsExpired() async throws {
        let clock = TestClock()
        let store = InMemoryTokenStore(storedTokens(expiresIn: 0, clock: clock))
        let refreshGate = Gate(), loginGate = Gate()
        let transport = StubTransport { _ in
            await refreshGate.wait()
            return StubTransport.response(400, #"{"error":"invalid_grant"}"#)
        }
        let m = makeManager(store: store, transport: transport, clock: clock)
        let refreshing = Task { try await m.validAccessToken() }
        try await waitUntil { transport.requests.count == 1 }
        let login = Task {
            try await m.login(manualCodeProvider: { _ in await loginGate.wait(); return "malformed" })
        }
        try await waitUntil { await m.state == .signingIn }
        refreshGate.open()
        _ = try? await refreshing.value
        loginGate.open()
        do { try await login.value; XCTFail("expected invalidManualCode") } catch {
            XCTAssertEqual(error as? AuthError, .invalidManualCode)
        }
        let state = await m.state
        XCTAssertEqual(state, .expired)
        XCTAssertNil(try store.load())
    }

    // MARK: refresh 저장 실패 (리뷰 #2)

    func testRefreshSaveFailureRetriesOnce() async throws {
        let clock = TestClock()
        let store = FlakySaveStore(storedTokens(expiresIn: 0, clock: clock), failSaves: 1)
        let transport = StubTransport { [tokenJSON] _ in StubTransport.response(200, tokenJSON) }
        let m = AuthManager(store: store, transport: transport, openURL: { _ in }, now: { clock.now }, callbackTimeout: 5)
        let token = try await m.validAccessToken()
        XCTAssertEqual(token, "AT_NEW")
        XCTAssertEqual(store.saveAttempts, 2)
        XCTAssertEqual(store.stored?.refreshToken, "RT_NEW")
    }

    func testRefreshSaveFailureStillReturnsTokenAndKeepsMemory() async throws {
        let clock = TestClock()
        let store = FlakySaveStore(storedTokens(expiresIn: 0, clock: clock), failSaves: .max)
        let transport = StubTransport { [tokenJSON] _ in StubTransport.response(200, tokenJSON) }
        let m = AuthManager(store: store, transport: transport, openURL: { _ in }, now: { clock.now }, callbackTimeout: 5)
        let token = try await m.validAccessToken()
        XCTAssertEqual(token, "AT_NEW")
        XCTAssertEqual(store.saveAttempts, 2)
        let state = await m.state
        XCTAssertEqual(state, .signedIn)
        let again = try await m.validAccessToken()
        XCTAssertEqual(again, "AT_NEW")
        XCTAssertEqual(transport.requests.count, 1)
    }

    // MARK: logout이 진행 중 로그인 취소 (리뷰 #6)

    func testLogoutCancelsPendingCallbackLogin() async throws {
        let store = InMemoryTokenStore()
        let opened = Gate()
        let transport = StubTransport { [tokenJSON] _ in StubTransport.response(200, tokenJSON) }
        let m = makeManager(store: store, transport: transport, opener: { _ in opened.open() })
        let login = Task { try await m.login() }
        await opened.wait()
        let start = Date()
        await m.logout()
        do { try await login.value; XCTFail("expected cancelled") } catch {
            XCTAssertEqual(error as? AuthError, .cancelled)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        let state = await m.state
        XCTAssertEqual(state, .signedOut)
        XCTAssertTrue(transport.requests.isEmpty)
        try await m.login(manualCodeProvider: { Self.manualCode($0) })
        let after = await m.state
        XCTAssertEqual(after, .signedIn)
    }

    func testLoginFinishingAfterLogoutIsDiscarded() async throws {
        let store = InMemoryTokenStore()
        let transport = StubTransport { [tokenJSON] _ in StubTransport.response(200, tokenJSON) }
        let m = makeManager(store: store, transport: transport)
        do {
            try await m.login(manualCodeProvider: { url in
                await m.logout()
                return Self.manualCode(url)
            })
            XCTFail("expected cancelled")
        } catch {
            XCTAssertEqual(error as? AuthError, .cancelled)
        }
        XCTAssertNil(try store.load())
        let state = await m.state
        XCTAssertEqual(state, .signedOut)
        do { _ = try await m.validAccessToken(); XCTFail() } catch {
            XCTAssertEqual(error as? AuthError, .notSignedIn)
        }
    }
}
