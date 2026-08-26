import AppKit
import ApplicationServices
import Foundation

enum TextInjectorError: LocalizedError {
    case accessibilityPermissionMissing
    case noFocusedTextInput
    case pasteFailed

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionMissing:
            return "缺少辅助功能权限，无法把文字放入当前输入框。"
        case .noFocusedTextInput:
            return "当前焦点不是输入框。请先点击要输入文字的位置，再按住 Fn。"
        case .pasteFailed:
            return "无法把识别结果粘贴到当前输入框。"
        }
    }
}

enum TextInsertionMethod: String {
    case accessibility
    case pasteboard
}

struct TextInsertionTarget {
    fileprivate let element: AXUIElement
}

@MainActor
final class TextInjector {
    func captureFocusedTarget() -> TextInsertionTarget? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success,
        let focusedValue
        else {
            return nil
        }

        let element = focusedValue as! AXUIElement
        guard isTextInput(element) else {
            return nil
        }

        return TextInsertionTarget(element: element)
    }

    func insert(
        _ text: String,
        target: TextInsertionTarget? = nil
    ) async throws -> TextInsertionMethod {
        guard PermissionManager.hasAccessibilityPermission,
              PermissionManager.hasEventPostingPermission
        else {
            throw TextInjectorError.accessibilityPermissionMissing
        }

        let resolvedTarget = target ?? captureFocusedTarget()
        do {
            try await insertUsingPasteboard(text, target: resolvedTarget)
            return .pasteboard
        } catch {
            if let resolvedTarget,
               insertUsingAccessibility(text, target: resolvedTarget) {
                return .accessibility
            }
            throw error
        }
    }

    private func insertUsingAccessibility(
        _ text: String,
        target: TextInsertionTarget
    ) -> Bool {
        var isSettable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            target.element,
            kAXSelectedTextAttribute as CFString,
            &isSettable
        ) == .success,
        isSettable.boolValue
        else {
            return false
        }

        return AXUIElementSetAttributeValue(
            target.element,
            kAXSelectedTextAttribute as CFString,
            text as CFString
        ) == .success
    }

    private func isTextInput(_ element: AXUIElement) -> Bool {
        if isAttributeSettable(
            kAXSelectedTextAttribute as CFString,
            on: element
        ) {
            return true
        }

        var roleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &roleValue
        ) == .success,
        let role = roleValue as? String
        else {
            return false
        }

        let textRoles = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String,
        ]
        return textRoles.contains(role)
    }

    private func isAttributeSettable(
        _ attribute: CFString,
        on element: AXUIElement
    ) -> Bool {
        var isSettable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(
            element,
            attribute,
            &isSettable
        ) == .success && isSettable.boolValue
    }

    private func insertUsingPasteboard(
        _ text: String,
        target: TextInsertionTarget?
    ) async throws {
        if let target {
            var processIdentifier: pid_t = 0
            if AXUIElementGetPid(target.element, &processIdentifier) == .success {
                NSRunningApplication(processIdentifier: processIdentifier)?
                    .activate(options: [.activateIgnoringOtherApps])
            }

            try? await Task.sleep(nanoseconds: 120_000_000)
            _ = AXUIElementSetAttributeValue(
                target.element,
                kAXFocusedAttribute as CFString,
                kCFBooleanTrue
            )
            try? await Task.sleep(nanoseconds: 80_000_000)
        }

        let pasteboard = NSPasteboard.general
        let snapshot = snapshotPasteboard(pasteboard)
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw TextInjectorError.pasteFailed
        }
        let injectionChangeCount = pasteboard.changeCount

        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: 9,
                keyDown: true
              ),
              let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: 9,
                keyDown: false
              )
        else {
            restore(snapshot, to: pasteboard)
            throw TextInjectorError.pasteFailed
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        try? await Task.sleep(nanoseconds: 700_000_000)
        if pasteboard.changeCount == injectionChangeCount {
            restore(snapshot, to: pasteboard)
        }
    }

    private func snapshotPasteboard(
        _ pasteboard: NSPasteboard
    ) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        }
    }

    private func restore(
        _ snapshot: [[NSPasteboard.PasteboardType: Data]],
        to pasteboard: NSPasteboard
    ) {
        pasteboard.clearContents()
        let items: [NSPasteboardItem] = snapshot.map { values in
            let item = NSPasteboardItem()
            for (type, data) in values {
                item.setData(data, forType: type)
            }
            return item
        }
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }
}
