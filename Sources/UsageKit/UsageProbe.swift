import CoreModels
import Foundation
import os

/// 일회성 진단: 사용량 API 쿼리 변형들의 응답 본문을 파일로 저장한다(GET 읽기 전용).
/// 토큰/헤더는 어떤 파일·로그에도 남기지 않는다.
public struct UsageProbe: Sendable {
    public struct Variant: Sendable, Equatable {
        public let name: String
        public let query: String // 빈 문자열이면 쿼리 없음
    }

    public static let variants: [Variant] = [
        Variant(name: "default", query: ""),
        Variant(name: "at_wall", query: "at_wall=1&skip_spend=1"),
        Variant(name: "cedar_ember", query: "cedar_ember=1&skip_spend=1"),
        Variant(name: "starry_waterfall", query: "starry_waterfall=cli_menu&skip_spend=1"),
        Variant(name: "at_wall_starry_waterfall", query: "at_wall=1&starry_waterfall=cli_menu&skip_spend=1"),
    ]

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ClawdCounter/probe")
    }

    static func url(for variant: Variant) -> URL {
        variant.query.isEmpty ? UsageClient.endpoint : URL(string: UsageClient.endpoint.absoluteString + "?" + variant.query)!
    }

    private let tokens: any TokenProviding
    private let transport: any UsageTransport
    private let directory: URL
    private let pause: @Sendable () async -> Void
    private let log = Logger(subsystem: "clawdcounter", category: "UsageProbe")

    public init(
        tokens: any TokenProviding,
        transport: any UsageTransport = UsageClient.defaultTransport,
        directory: URL = UsageProbe.defaultDirectory,
        pause: @escaping @Sendable () async -> Void = { try? await Task.sleep(for: .seconds(1)) }
    ) {
        self.tokens = tokens
        self.transport = transport
        self.directory = directory
        self.pause = pause
    }

    /// 변형을 순차 호출한다. 429 또는 토큰 오류면 중단하고 index 에 기록한다.
    public func run() async {
        var lines: [String] = []
        do {
            try prepareDirectory()
        } catch {
            log.error("probe: cannot create output directory")
            return
        }

        for (i, variant) in Self.variants.enumerated() {
            if Task.isCancelled { lines.append("\(variant.name) cancelled"); break }
            if i > 0 { await pause() }

            let token: String
            do {
                token = try await tokens.validAccessToken()
            } catch {
                lines.append("\(variant.name) token_unavailable (stopped)")
                break
            }

            var request = URLRequest(url: Self.url(for: variant), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            request.httpMethod = "GET"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.setValue("ClawdCounter/0.1", forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            do {
                let (data, response) = try await transport.perform(request)
                let status = response.statusCode
                if status == 429 {
                    lines.append("\(variant.name) 429 (stopped)")
                    break
                }
                write(data, to: "\(variant.name).json")
                lines.append("\(variant.name) \(status)")
            } catch {
                lines.append("\(variant.name) network_error")
            }
            log.info("probe: \(variant.name, privacy: .public) done")
        }

        write(Data((lines.joined(separator: "\n") + "\n").utf8), to: "index.txt")
    }

    private func prepareDirectory() throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private func write(_ data: Data, to name: String) {
        let path = directory.appendingPathComponent(name).path
        let fm = FileManager.default
        if fm.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600]) {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        } else {
            log.error("probe: failed to write \(name, privacy: .public)")
        }
    }
}
