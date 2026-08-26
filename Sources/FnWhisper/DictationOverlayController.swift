import AppKit

@MainActor
final class DictationOverlayController {
    private let panel: NSPanel
    private let iconView: NSImageView
    private let badgeLabel: NSTextField
    private let statusLabel: NSTextField
    private let progressIndicator: NSProgressIndicator

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 410, height: 92),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true

        let background = NSVisualEffectView(frame: panel.contentView?.bounds ?? .zero)
        background.autoresizingMask = [.width, .height]
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 18
        background.layer?.masksToBounds = true

        iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 25,
            weight: .medium
        )
        iconView.contentTintColor = .systemRed

        badgeLabel = NSTextField(labelWithString: "")
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeLabel.font = .systemFont(ofSize: 24, weight: .semibold)
        badgeLabel.textColor = .systemGreen
        badgeLabel.alignment = .center
        badgeLabel.isHidden = true

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 16, weight: .medium)
        statusLabel.textColor = .labelColor
        statusLabel.alignment = .center
        statusLabel.lineBreakMode = .byTruncatingTail

        progressIndicator = NSProgressIndicator()
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false

        let row = NSStackView(
            views: [iconView, badgeLabel, statusLabel, progressIndicator]
        )
        row.translatesAutoresizingMaskIntoConstraints = false
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        background.addSubview(row)
        panel.contentView = background

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 30),
            iconView.heightAnchor.constraint(equalToConstant: 30),
            badgeLabel.widthAnchor.constraint(equalToConstant: 30),
            progressIndicator.widthAnchor.constraint(equalToConstant: 18),
            row.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            row.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            row.leadingAnchor.constraint(greaterThanOrEqualTo: background.leadingAnchor, constant: 22),
            row.trailingAnchor.constraint(lessThanOrEqualTo: background.trailingAnchor, constant: -22),
        ])
    }

    func update(for phase: DictationPhase) {
        switch phase {
        case .idle, .waitingForPermissions:
            hide()
        case .preparing:
            show(
                symbol: "mic.badge.plus",
                text: "正在启动麦克风…",
                tint: .systemOrange,
                showsProgress: true
            )
        case .recording:
            show(
                symbol: "waveform",
                text: "正在听：松开 Fn 完成",
                tint: .systemRed,
                showsProgress: false
            )
        case .transcribing:
            show(
                symbol: "text.bubble",
                text: "正在本地转成文字…",
                tint: .systemBlue,
                showsProgress: true
            )
        case let .completed(preview, route):
            show(
                symbol: nil,
                badge: route.indicatorText,
                text: route.completionText,
                tint: .systemGreen,
                showsProgress: false,
                accessibilityDescription: "处理完成。\(route.completionText)。处理路径：\(route.displayText)。识别预览：\(preview)"
            )
        case let .failed(message):
            show(
                symbol: "exclamationmark.triangle.fill",
                text: message,
                tint: .systemOrange,
                showsProgress: false
            )
        }
    }

    private func show(
        symbol: String?,
        badge: String? = nil,
        text: String,
        tint: NSColor,
        showsProgress: Bool,
        accessibilityDescription: String? = nil
    ) {
        if let symbol {
            iconView.image = NSImage(
                systemSymbolName: symbol,
                accessibilityDescription: accessibilityDescription ?? text
            )
            iconView.isHidden = false
        } else {
            iconView.image = nil
            iconView.isHidden = true
        }
        if let badge {
            badgeLabel.stringValue = badge
            badgeLabel.textColor = tint
            badgeLabel.setAccessibilityLabel(
                accessibilityDescription ?? "\(badge) \(text)"
            )
            badgeLabel.isHidden = false
        } else {
            badgeLabel.stringValue = ""
            badgeLabel.isHidden = true
        }
        iconView.contentTintColor = tint
        statusLabel.stringValue = text
        statusLabel.setAccessibilityLabel(accessibilityDescription ?? text)

        if showsProgress {
            progressIndicator.startAnimation(nil)
        } else {
            progressIndicator.stopAnimation(nil)
        }

        positionPanel()
        panel.orderFrontRegardless()
    }

    private func hide() {
        progressIndicator.stopAnimation(nil)
        panel.orderOut(nil)
    }

    private func positionPanel() {
        guard let screen = NSScreen.screens.first(where: {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        }) ?? NSScreen.main else {
            return
        }

        let visibleFrame = screen.visibleFrame
        let origin = NSPoint(
            x: visibleFrame.midX - panel.frame.width / 2,
            y: visibleFrame.minY + max(90, visibleFrame.height * 0.16)
        )
        panel.setFrameOrigin(origin)
    }
}
