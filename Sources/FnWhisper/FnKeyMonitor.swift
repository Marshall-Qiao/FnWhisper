import ApplicationServices
import Foundation
import os

enum FnKeyMonitorError: LocalizedError {
    case eventTapUnavailable

    var errorDescription: String? {
        switch self {
        case .eventTapUnavailable:
            return "无法监听 Fn 键。请在系统设置中授予输入监听权限，然后重新检查。"
        }
    }
}

final class FnKeyMonitor {
    var onStartRecording: (() -> Void)?
    var onStopRecording: (() -> Void)?

    private let holdDuration: TimeInterval
    private var stateMachine = FnPressStateMachine()
    private var activationWorkItem: DispatchWorkItem?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let logger = Logger(
        subsystem: "com.marshall.fnwhisper",
        category: "FnKeyMonitor"
    )

    private static let eventCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else {
            return Unmanaged.passUnretained(event)
        }

        let monitor = Unmanaged<FnKeyMonitor>
            .fromOpaque(userInfo)
            .takeUnretainedValue()
        return monitor.receive(type: type, event: event)
            ? nil
            : Unmanaged.passUnretained(event)
    }

    init(holdDuration: TimeInterval) {
        self.holdDuration = holdDuration
    }

    var isRunning: Bool {
        eventTap != nil
    }

    func start() throws {
        guard eventTap == nil else {
            return
        }

        let mask = CGEventMask(1) << CGEventType.flagsChanged.rawValue
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.eventCallback,
            userInfo: userInfo
        ) else {
            throw FnKeyMonitorError.eventTapUnavailable
        }

        let runLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            eventTap,
            0
        )
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)

        self.eventTap = eventTap
        self.runLoopSource = runLoopSource
        logger.notice("Fn event tap started")
    }

    func stop() {
        activationWorkItem?.cancel()
        activationWorkItem = nil
        stateMachine.reset()

        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }

        eventTap = nil
        runLoopSource = nil
    }

    private func receive(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return false
        }

        guard type == .flagsChanged else {
            return false
        }

        let fnIsPressed = event.flags.contains(.maskSecondaryFn)
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let shouldConsume = FnEventConsumptionPolicy.shouldConsume(
            keyCode: keyCode
        )
        if shouldConsume {
            logger.info("Fn event received: pressed=\(fnIsPressed, privacy: .public)")
        }
        if let action = stateMachine.handle(fnIsPressed: fnIsPressed) {
            perform(action)
        }
        return shouldConsume
    }

    private func perform(_ action: FnPressStateMachine.Action) {
        switch action {
        case .scheduleActivation:
            activationWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self,
                      self.stateMachine.activationDelayElapsed() == .startRecording
                else {
                    return
                }
                self.logger.notice("Fn hold threshold reached; starting dictation")
                self.onStartRecording?()
            }
            activationWorkItem = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + holdDuration,
                execute: workItem
            )
        case .cancelActivation:
            activationWorkItem?.cancel()
            activationWorkItem = nil
        case .startRecording:
            onStartRecording?()
        case .stopRecording:
            activationWorkItem?.cancel()
            activationWorkItem = nil
            onStopRecording?()
        }
    }

    deinit {
        stop()
    }
}
