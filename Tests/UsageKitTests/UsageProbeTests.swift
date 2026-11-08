import CoreModels
import Foundation
import Testing
@testable import UsageKit

@Suite struct UsageProbeTests {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("probe-\(UUID().uuidString)/probe")
    }

    private func perms(_ url: URL) throws -> Int {
        try (FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func probe(_ dir: URL, tokens: StubTokens = StubTokens(), _ handler: @escaping StubTransport.Handler)
        -> (UsageProbe, StubTransport)
    {
        let transport = StubTransport(handler)
        return (UsageProbe(tokens: tokens, transport: transport, directory: dir, pause: {}), transport)
    }

    @Test func requestsAllVariantsAsGet() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let (p, transport) = probe(dir) { _ in StubTransport.response(200, #"{"ok":true}"#) }
        await p.run()

        let urls = transport.requests.map { $0.url!.absoluteString }
        let base = "https://api.anthropic.com/api/oauth/usage"
        #expect(urls == [
            base,
            base + "?at_wall=1&skip_spend=1",
            base + "?cedar_ember=1&skip_spend=1",
            base + "?starry_waterfall=cli_menu&skip_spend=1",
            base + "?at_wall=1&starry_waterfall=cli_menu&skip_spend=1",
        ])
        for r in transport.requests {
            #expect(r.httpMethod == "GET")
            #expect(r.httpBody == nil)
            #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer test-token-xyz")
            #expect(r.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
            #expect(r.value(forHTTPHeaderField: "User-Agent") == "ClawdCounter/0.1")
        }
    }

    @Test func savesBodiesWithPermissionsAndIndex() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let (p, _) = probe(dir) { req in
            StubTransport.response(200, "body:\(req.url!.query ?? "none")")
        }
        await p.run()

        #expect(try perms(dir) == 0o700)
        for v in UsageProbe.variants {
            let f = dir.appendingPathComponent("\(v.name).json")
            #expect(try perms(f) == 0o600)
            #expect(try String(contentsOf: f, encoding: .utf8) == "body:\(v.query.isEmpty ? "none" : v.query)")
        }
        let index = dir.appendingPathComponent("index.txt")
        #expect(try perms(index) == 0o600)
        let lines = try String(contentsOf: index, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines == UsageProbe.variants.map { "\($0.name) 200" })
    }

    @Test func tokenNeverPersisted() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let (p, _) = probe(dir, tokens: StubTokens(token: "SECRET-TOKEN-123")) { _ in StubTransport.response(200, "{}") }
        await p.run()

        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(!names.isEmpty)
        for n in names {
            let text = try String(contentsOf: dir.appendingPathComponent(n), encoding: .utf8)
            #expect(!text.contains("SECRET-TOKEN-123"))
            #expect(!text.contains("Bearer"))
        }
    }

    @Test func stopsOn429AndRecordsIt() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let (p, transport) = probe(dir) { req in
            req.url!.query == "at_wall=1&skip_spend=1" ? StubTransport.response(429, "slow down") : StubTransport.response(200, "{}")
        }
        await p.run()

        #expect(transport.requests.count == 2)
        let lines = try String(contentsOf: dir.appendingPathComponent("index.txt"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        #expect(lines == ["default 200", "at_wall 429 (stopped)"])
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("at_wall.json").path))
    }

    @Test func recordsNon2xxStatusAndContinues() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let (p, transport) = probe(dir) { req in
            req.url!.query == "cedar_ember=1&skip_spend=1" ? StubTransport.response(400, "{\"e\":1}") : StubTransport.response(200, "{}")
        }
        await p.run()

        #expect(transport.requests.count == UsageProbe.variants.count)
        let index = try String(contentsOf: dir.appendingPathComponent("index.txt"), encoding: .utf8)
        #expect(index.contains("cedar_ember 400"))
    }

    @Test func tokenFailureStopsWithoutRequests() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        var tokens = StubTokens()
        tokens.error = UsageError.tokenUnavailable
        let (p, transport) = probe(dir, tokens: tokens) { _ in StubTransport.response(200, "{}") }
        await p.run()

        #expect(transport.requests.isEmpty)
        let index = try String(contentsOf: dir.appendingPathComponent("index.txt"), encoding: .utf8)
        #expect(index == "default token_unavailable (stopped)\n")
    }
}
