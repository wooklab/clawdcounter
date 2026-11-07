import CryptoKit
import Foundation
import Security

/// RFC 7636 PKCE (S256).
public enum PKCE {
    /// 32바이트 난수를 base64url 인코딩한 43자 verifier.
    public static func makeVerifier() -> String {
        base64URL(randomBytes(32))
    }

    public static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// OAuth state 값.
    public static func makeState() -> String {
        base64URL(randomBytes(32))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return Data(bytes)
    }
}
