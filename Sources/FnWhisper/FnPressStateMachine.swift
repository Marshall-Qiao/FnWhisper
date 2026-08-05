import Foundation

struct FnPressStateMachine {
    enum State: Equatable {
        case idle
        case armed
        case recording
    }

    enum Action: Equatable {
        case scheduleActivation
        case cancelActivation
        case startRecording
        case stopRecording
    }

    private(set) var state: State = .idle

    mutating func handle(fnIsPressed: Bool) -> Action? {
        switch (state, fnIsPressed) {
        case (.idle, true):
            state = .armed
            return .scheduleActivation
        case (.armed, false):
            state = .idle
            return .cancelActivation
        case (.recording, false):
            state = .idle
            return .stopRecording
        default:
            return nil
        }
    }

    mutating func activationDelayElapsed() -> Action? {
        guard state == .armed else {
            return nil
        }

        state = .recording
        return .startRecording
    }

    mutating func reset() {
        state = .idle
    }
}

enum FnEventConsumptionPolicy {
    static let functionKeyCode: Int64 = 63

    static func shouldConsume(keyCode: Int64) -> Bool {
        keyCode == functionKeyCode
    }
}
