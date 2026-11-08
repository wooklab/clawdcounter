import Foundation

/// 세션 파일 `status` 문자열 → 분류 매핑.
/// claude 2.1.319 바이너리에서 확인된 값: `busy`, `shell`, `idle`, `waiting`
/// (`waiting`일 때 `waitingFor` 문자열이 함께 기록됨). 값이 바뀌면 여기만 고친다.
public struct StatusMapping: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case active, waiting, idle }

    public var active: Set<String>
    public var waiting: Set<String>
    public var idle: Set<String>

    public init(
        active: Set<String> = ["busy", "shell"],
        waiting: Set<String> = ["waiting"],
        idle: Set<String> = ["idle"]
    ) {
        self.active = active
        self.waiting = waiting
        self.idle = idle
    }

    public static let `default` = StatusMapping()

    /// 알 수 없는(또는 누락된) 값은 `known == false`로 표시하고 idle로 취급한다.
    func classify(_ status: String?) -> (kind: Kind, known: Bool) {
        guard let status else { return (.idle, false) }
        if active.contains(status) { return (.active, true) }
        if waiting.contains(status) { return (.waiting, true) }
        if idle.contains(status) { return (.idle, true) }
        return (.idle, false)
    }
}
