import ApplicationServices
import Foundation

enum FnEventProbeError: LocalizedError {
    case eventTapUnavailable

    var errorDescription: String? {
        "无法创建 Fn 事件探针，请确认已授予输入监听权限。"
    }
}

final class FnEventProbe {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private(set) var observedFnEvent = false

    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else {
            return Unmanaged.passUnretained(event)
        }

        let probe = Unmanaged<FnEventProbe>
            .fromOpaque(userInfo)
            .takeUnretainedValue()
        probe.receive(type: type, event: event)
        return Unmanaged.passUnretained(event)
    }

    func run(duration: TimeInterval) throws -> Bool {
        let mask = CGEventMask(1) << CGEventType.flagsChanged.rawValue
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: Self.callback,
            userInfo: userInfo
        ) else {
            throw FnEventProbeError.eventTapUnavailable
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        self.eventTap = eventTap
        runLoopSource = source

        print("Fn 探针已启动，请在 \(Int(duration)) 秒内按住并松开 Fn。")
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            RunLoop.current.run(
                mode: .default,
                before: min(deadline, Date().addingTimeInterval(0.2))
            )
        }

        stop()
        print(observedFnEvent ? "结果：检测到 Fn 事件。" : "结果：没有检测到 Fn 事件。")
        return observedFnEvent
    }

    private func receive(type: CGEventType, event: CGEvent) {
        guard type == .flagsChanged else {
            return
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let fnIsPressed = event.flags.contains(.maskSecondaryFn)
        let rawFlags = event.flags.rawValue
        print("flagsChanged keyCode=\(keyCode) fn=\(fnIsPressed) flags=0x\(String(rawFlags, radix: 16))")

        if keyCode == FnEventConsumptionPolicy.functionKeyCode || fnIsPressed {
            observedFnEvent = true
        }
    }

    private func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    deinit {
        stop()
    }
}
