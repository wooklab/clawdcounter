import Foundation
import Security

/// 저장되는 토큰 묶음. description은 항상 마스킹된다.
public struct StoredTokens: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public var scopes: [String]

    public init(accessToken: String, refreshToken: String, expiresAt: Date, scopes: [String]) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scopes = scopes
    }

    public var description: String { "StoredTokens(<redacted>, expiresAt: \(expiresAt))" }
    public var debugDescription: String { description }
}

public protocol TokenStore: Sendable {
    func load() throws -> StoredTokens?
    func save(_ tokens: StoredTokens) throws
    func delete() throws
}

/// 테스트용 인메모리 저장소.
public final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: StoredTokens?

    public init(_ tokens: StoredTokens? = nil) { self.tokens = tokens }

    public func load() throws -> StoredTokens? { lock.withLock { tokens } }
    public func save(_ tokens: StoredTokens) throws { lock.withLock { self.tokens = tokens } }
    public func delete() throws { lock.withLock { tokens = nil } }
}

/// 앱 전용 키체인 저장소 (Claude Code 항목과 무관한 별도 service).
// TODO(리뷰 #7): kSecUseDataProtectionKeychain(데이터 프로텍션 키체인) 사용 검토.
public struct KeychainTokenStore: TokenStore {
    public let service: String
    public let account: String

    public init(service: String = "ClawdCounter-credentials", account: String = "default") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func load() throws -> StoredTokens? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw AuthError.keychain(status) }
        guard let tokens = try? JSONDecoder().decode(StoredTokens.self, from: data) else {
            throw AuthError.keychain(errSecDecode)
        }
        return tokens
    }

    public func save(_ tokens: StoredTokens) throws {
        let data: Data
        do { data = try JSONEncoder().encode(tokens) } catch { throw AuthError.keychain(errSecParam) }
        var add = baseQuery
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        var status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let attrs: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            ]
            status = SecItemUpdate(baseQuery as CFDictionary, attrs as CFDictionary)
        }
        guard status == errSecSuccess else { throw AuthError.keychain(status) }
    }

    public func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AuthError.keychain(status) }
    }
}
