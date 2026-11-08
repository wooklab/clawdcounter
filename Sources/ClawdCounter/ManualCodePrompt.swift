import AppKit
import AuthKit
import CoreModels

/// 로컬 콜백 서버를 쓸 수 없을 때의 수동 코드 입력창. 입력값은 로그에 남기지 않는다.
@MainActor
enum ManualCodePrompt {
    static func ask() throws -> String {
        let alert = NSAlert()
        alert.messageText = L10n.tr(.manualCodeTitle)
        alert.informativeText = L10n.tr(.manualCodeMessage)
        alert.addButton(withTitle: L10n.tr(.manualCodeLoginButton))
        alert.addButton(withTitle: L10n.tr(.cancel))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = L10n.tr(.manualCodePlaceholder)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { throw AuthError.cancelled }
        return field.stringValue
    }

    static func showFailure(_ error: AuthError) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.tr(.loginFailed)
        alert.informativeText = error.description
        alert.addButton(withTitle: L10n.tr(.ok))
        NSApp.activate()
        alert.runModal()
    }
}
