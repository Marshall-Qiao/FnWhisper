import ApplicationServices
import AVFoundation
import Foundation

enum PermissionManager {
    static func requestInputPermissions() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        if !CGPreflightListenEventAccess() {
            _ = CGRequestListenEventAccess()
        }
        if !CGPreflightPostEventAccess() {
            _ = CGRequestPostEventAccess()
        }
    }

    static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    static var hasInputListeningPermission: Bool {
        CGPreflightListenEventAccess()
    }

    static var hasEventPostingPermission: Bool {
        CGPreflightPostEventAccess()
    }

    static var missingInputPermissionNames: [String] {
        var names: [String] = []
        if !hasAccessibilityPermission {
            names.append("辅助功能")
        }
        if !hasInputListeningPermission {
            names.append("输入监听")
        }
        if !hasEventPostingPermission {
            names.append("事件输入")
        }
        return names
    }

    static var diagnosticReport: String {
        """
        辅助功能：\(hasAccessibilityPermission ? "已授权" : "未授权")
        输入监听：\(hasInputListeningPermission ? "已授权" : "未授权")
        事件输入：\(hasEventPostingPermission ? "已授权" : "未授权")
        麦克风：\(microphoneStatusDescription)
        """
    }

    static var microphoneStatusDescription: String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return "已授权"
        case .denied:
            return "已拒绝"
        case .restricted:
            return "受系统限制"
        case .notDetermined:
            return "首次录音时请求"
        @unknown default:
            return "未知"
        }
    }
}
