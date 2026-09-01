import Foundation

enum AudioCallbackLossAction: Equatable, Sendable {
    case none
    case finishInPreview
    case fail
}

struct AudioCallbackHealth: Equatable, Sendable {
    let shouldZeroMeter: Bool
    let isDisconnected: Bool
    let lossAction: AudioCallbackLossAction
}

enum AudioCallbackHealthPolicy {
    static let meterDecayDelay: TimeInterval = 0.250
    static let disconnectDelay: TimeInterval = 0.500
    static let terminalDelay: TimeInterval = 2.000

    static func evaluate(
        secondsSinceLastCallback: TimeInterval,
        capturedOutputFrames: Int64
    ) -> AudioCallbackHealth {
        let elapsed = max(0, secondsSinceLastCallback)
        let terminal = elapsed >= terminalDelay
        return AudioCallbackHealth(
            shouldZeroMeter: elapsed >= meterDecayDelay,
            isDisconnected: elapsed >= disconnectDelay,
            lossAction: terminal
                ? (capturedOutputFrames > 0 ? .finishInPreview : .fail)
                : .none
        )
    }
}
