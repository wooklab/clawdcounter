import AppKit
import AuthKit

/// 로컬 콜백 서버를 쓸 수 없을 때의 수동 코드 입력창. 입력값은 로그에 남기지 않는다.
@MainActor
enum ManualCodePrompt {
    static func ask() throws -> String {
        let alert = NSAlert()
        alert.messageText = "Claude 로그인 코드 입력"
        alert.informativeText = "브라우저에서 로그인한 뒤 표시되는 코드를 아래에 붙여넣으세요."
        alert.addButton(withTitle: "로그인")
        alert.addButton(withTitle: "취소")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "코드#상태"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { throw AuthError.cancelled }
        return field.stringValue
    }

    static func showFailure(_ error: AuthError) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "로그인에 실패했습니다"
        alert.informativeText = error.description
        alert.addButton(withTitle: "확인")
        NSApp.activate()
        alert.runModal()
    }
}
