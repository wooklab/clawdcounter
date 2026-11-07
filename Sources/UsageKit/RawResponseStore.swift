import Foundation
import os

/// 디버그용: 마지막 사용량 응답 원문을 `last_usage_raw.json` 에 덮어쓴다(0600). 토큰/헤더는 받지도 않는다.
public struct RawResponseStore: Sendable {
    public static var defaultFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ClawdCounter/last_usage_raw.json")
    }

    private let fileURL: URL
    private let log = Logger(subsystem: "clawdcounter", category: "UsageClient")

    public init(fileURL: URL = RawResponseStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    /// 실패해도 사용량 조회에는 영향 없음(로그만).
    public func save(_ data: Data) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            guard fm.createFile(atPath: fileURL.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                log.error("failed to write raw usage response")
                return
            }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path) // 기존 파일 권한 보정
        } catch {
            log.error("failed to save raw usage response")
        }
    }
}
