import AppKit
import AVFoundation
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let configuration = AppConfiguration()
    private var statusItem: NSStatusItem!
    private var statusMenuItem: NSMenuItem!
    private var permissionTimer: Timer?
    private var fnMonitor: FnKeyMonitor?
    private var coordinator: DictationCoordinator?
    private let overlayController = DictationOverlayController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildStatusMenu()
        configureRuntime()
        PermissionManager.requestInputPermissions()
        attemptToStartFnMonitor()

        permissionTimer = Timer.scheduledTimer(
            withTimeInterval: 2,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.attemptToStartFnMonitor()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        permissionTimer?.invalidate()
        fnMonitor?.stop()
    }

    private func configureRuntime() {
        guard let executableURL = configuration.resolveWhisperCLI() else {
            updateStatus(
                .failed(WhisperTranscriberError.executableMissing.localizedDescription)
            )
            return
        }
        guard FileManager.default.fileExists(atPath: configuration.modelURL.path) else {
            updateStatus(
                .failed(
                    WhisperTranscriberError
                        .modelMissing(configuration.modelURL)
                        .localizedDescription
                )
            )
            return
        }

        let transcriber = WhisperTranscriber(
            executableURL: executableURL,
            modelURL: configuration.modelURL,
            language: configuration.language,
            threadCount: configuration.threadCount,
            useGPU: configuration.useGPU
        )
        let coordinator = DictationCoordinator(
            recorder: AudioRecorder(),
            transcriber: transcriber,
            textInjector: TextInjector()
        )
        coordinator.onPhaseChange = { [weak self] phase in
            self?.updateStatus(phase)
        }
        self.coordinator = coordinator
        updateStatus(.idle)
    }

    private func attemptToStartFnMonitor() {
        guard coordinator != nil else {
            return
        }

        let missingPermissions = PermissionManager.missingInputPermissionNames
        guard missingPermissions.isEmpty else {
            if fnMonitor?.isRunning == true {
                fnMonitor?.stop()
                fnMonitor = nil
            }
            updateStatus(
                .waitingForPermissions(missingPermissions.joined(separator: "、"))
            )
            return
        }

        if fnMonitor?.isRunning == true {
            return
        }

        let monitor = FnKeyMonitor(holdDuration: configuration.holdDuration)
        monitor.onStartRecording = { [weak self] in
            self?.coordinator?.beginDictation()
        }
        monitor.onStopRecording = { [weak self] in
            self?.coordinator?.endDictation()
        }

        do {
            try monitor.start()
            fnMonitor = monitor
            updateStatus(.idle)
        } catch {
            updateStatus(.failed(error.localizedDescription))
        }
    }

    private func buildStatusMenu() {
        statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.squareLength
        )
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "waveform",
                accessibilityDescription: "FnWhisper"
            )
            button.toolTip = "FnWhisper"
        }

        let menu = NSMenu()
        statusMenuItem = NSMenuItem(title: "正在启动…", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())

        let checkItem = NSMenuItem(
            title: "检查权限与运行环境",
            action: #selector(checkEnvironment),
            keyEquivalent: ""
        )
        checkItem.target = self
        menu.addItem(checkItem)

        let modelItem = NSMenuItem(
            title: "打开模型目录",
            action: #selector(openModelDirectory),
            keyEquivalent: ""
        )
        modelItem.target = self
        menu.addItem(modelItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(
            title: "退出 FnWhisper",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    private func updateStatus(_ phase: DictationPhase) {
        overlayController.update(for: phase)
        statusMenuItem?.title = phase.statusText
        statusItem?.button?.toolTip = phase.statusText

        let symbolName: String
        switch phase {
        case .waitingForPermissions:
            symbolName = "lock.trianglebadge.exclamationmark"
        case .idle, .completed:
            symbolName = "waveform"
        case .preparing, .transcribing:
            symbolName = "ellipsis.circle"
        case .recording:
            symbolName = "mic.fill"
        case .failed:
            symbolName = "exclamationmark.triangle"
        }
        statusItem?.button?.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: phase.statusText
        )
    }

    @objc
    private func checkEnvironment() {
        PermissionManager.requestInputPermissions()
        configureRuntime()
        attemptToStartFnMonitor()

        let cliDescription = configuration.resolveWhisperCLI()?.path ?? "未找到"
        let modelExists = FileManager.default.fileExists(
            atPath: configuration.modelURL.path
        )
        let report = """
        Whisper CLI：\(cliDescription)
        模型：\(modelExists ? "已找到" : "未找到")
        模型路径：\(configuration.modelURL.path)
        计算后端：\(configuration.useGPU ? "Metal GPU（失败时自动回退 CPU）" : "CPU")
        CPU 线程：\(configuration.threadCount)
        \(PermissionManager.diagnosticReport)
        """

        let alert = NSAlert()
        alert.messageText = "FnWhisper 运行环境"
        alert.informativeText = report
        alert.alertStyle = modelExists && configuration.resolveWhisperCLI() != nil
            ? .informational
            : .warning
        alert.addButton(withTitle: "确定")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc
    private func openModelDirectory() {
        let directory = configuration.modelURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        NSWorkspace.shared.open(directory)
    }

    @objc
    private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
