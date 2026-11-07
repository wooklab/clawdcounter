import Foundation
import Network

/// 127.0.0.1 임의 포트에서 OAuth 리다이렉트 1회를 받는 일회용 HTTP 서버.
/// 모든 가변 상태는 `queue`에서만 접근한다.
final class OAuthCallbackServer: @unchecked Sendable {
    struct Callback: Sendable {
        let code: String
        /// 브라우저 응답: true면 successURL로 302, false면 오류 페이지.
        let respond: @Sendable (_ success: Bool) -> Void
    }

    private let queue = DispatchQueue(label: "ClawdCounter.OAuthCallbackServer")
    private let expectedState: String
    private let callbackPath: String
    private let successURL: URL
    private var listener: NWListener?

    private var startContinuation: CheckedContinuation<UInt16, Error>?
    private var waitContinuation: CheckedContinuation<Callback, Error>?
    private var pendingResult: Result<Callback, Error>?
    private var finished = false

    init(expectedState: String, callbackPath: String = "/callback", successURL: URL) {
        self.expectedState = expectedState
        self.callbackPath = callbackPath
        self.successURL = successURL
    }

    /// 리스너를 시작하고 바인딩된 포트를 반환한다.
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            queue.async { [self] in
                let params = NWParameters.tcp
                params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                let listener: NWListener
                do { listener = try NWListener(using: params) } catch {
                    cont.resume(throwing: AuthError.callbackServerUnavailable)
                    return
                }
                self.listener = listener
                self.startContinuation = cont
                listener.stateUpdateHandler = { [weak self] state in self?.handleListenerState(state) }
                listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
                listener.start(queue: queue)
            }
        }
    }

    /// 콜백 1회를 기다린다. 타임아웃/취소 시 에러.
    func waitForCallback(timeout: TimeInterval) async throws -> Callback {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Callback, Error>) in
                queue.async { [self] in
                    if let pendingResult {
                        self.pendingResult = nil
                        cont.resume(with: pendingResult)
                        return
                    }
                    if finished {
                        cont.resume(throwing: AuthError.cancelled)
                        return
                    }
                    waitContinuation = cont
                    queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                        self?.finish(.failure(AuthError.timeout))
                    }
                }
            }
        } onCancel: {
            queue.async { [weak self] in self?.finish(.failure(AuthError.cancelled)) }
        }
    }

    /// 리스너를 닫는다(대기 중이면 취소로 종료). 이미 받은 연결의 응답은 영향 없음.
    func stop() {
        queue.async { [weak self] in self?.finish(.failure(AuthError.cancelled)) }
    }

    // MARK: - queue 내부

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            if let cont = startContinuation, let port = listener?.port?.rawValue {
                startContinuation = nil
                cont.resume(returning: port)
            }
        case .failed, .cancelled:
            if let cont = startContinuation {
                startContinuation = nil
                cont.resume(throwing: AuthError.callbackServerUnavailable)
            }
            finish(.failure(AuthError.callbackServerUnavailable))
        default:
            break
        }
    }

    private func finish(_ result: Result<Callback, Error>) {
        guard !finished else { return }
        finished = true
        listener?.cancel()
        listener = nil
        if let cont = waitContinuation {
            waitContinuation = nil
            cont.resume(with: result)
        } else {
            pendingResult = result
        }
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8))
            if headerEnd != nil || isComplete || error != nil || buffer.count > 16384 {
                self.handleRequest(conn, buffer: buffer)
            } else {
                self.receive(conn, buffer: buffer)
            }
        }
    }

    private func handleRequest(_ conn: NWConnection, buffer: Data) {
        guard let text = String(data: buffer, encoding: .utf8),
              let line = text.split(separator: "\r\n", maxSplits: 1).first
        else { return send(conn, status: "400 Bad Request", body: "Bad request") }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET",
              let comps = URLComponents(string: "http://localhost" + parts[1])
        else { return send(conn, status: "400 Bad Request", body: "Bad request") }
        guard comps.path == callbackPath, !finished else {
            return send(conn, status: "404 Not Found", body: "Not found")
        }
        let items = comps.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        guard value("state") == expectedState else {
            send(conn, status: "400 Bad Request", body: "State mismatch")
            return finish(.failure(AuthError.stateMismatch))
        }
        guard let code = value("code"), !code.isEmpty else {
            send(conn, status: "400 Bad Request", body: "Authorization failed")
            let err = value("error").map(AuthError.sanitizedErrorCode) ?? "no_code"
            return finish(.failure(AuthError.authorizationDenied(err)))
        }
        let successURL = self.successURL
        let callback = Callback(code: code) { [weak self] success in
            guard let self else { conn.cancel(); return }
            self.queue.async {
                if success {
                    self.send(conn, status: "302 Found", body: "", extraHeaders: "Location: \(successURL.absoluteString)\r\n")
                } else {
                    self.send(conn, status: "400 Bad Request", body: "Sign-in failed. Return to ClawdCounter and try again.")
                }
            }
        }
        finish(.success(callback))
    }

    private func send(_ conn: NWConnection, status: String, body: String, extraHeaders: String = "") {
        let bodyData = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\n\(extraHeaders)Content-Type: text/plain; charset=utf-8\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + bodyData, completion: .contentProcessed { _ in conn.cancel() })
    }
}
