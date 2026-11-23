import Foundation

/// Input events fed to `DoubleOptionDetector` from `CGEventTap` (or unit tests).
public enum HotkeyInputEvent: Equatable, Sendable {
    /// Option modifier pressed with no other primary modifiers held.
    case optionDown
    /// Option modifier released cleanly.
    case optionUp
    /// Any regular key press, mouse click, or another modifier (Cmd/Ctrl/Shift).
    case interruption
}

/// Pure, deterministic state machine that detects a clean double-tap of the macOS Option (`⌥`) key.
///
/// Guarantees:
/// - Holding Option (`> maxTapDuration`) does not count as a tap.
/// - Chords like `⌥+←`, `⌥+Backspace`, `⌥+e`, or `⌥+Click` immediately cancel the sequence.
/// - Rapid triple-taps trigger only once before returning to `.idle`.
public struct DoubleOptionDetector: Sendable {
    public enum State: Equatable, Sendable {
        case idle
        case firstDown(startedAt: TimeInterval)
        case awaitingSecondDown(firstReleasedAt: TimeInterval)
        case secondDown(startedAt: TimeInterval)
    }

    public var maxTapDuration: TimeInterval
    public var maxDoubleTapInterval: TimeInterval
    public private(set) var state: State = .idle

    public init(
        maxTapDuration: TimeInterval = 0.26,
        maxDoubleTapInterval: TimeInterval = 0.36
    ) {
        self.maxTapDuration = maxTapDuration
        self.maxDoubleTapInterval = maxDoubleTapInterval
    }

    /// Resets the state machine back to `.idle`.
    public mutating func reset() {
        state = .idle
    }

    /// Processes an event at monotonic timestamp `timestamp` (seconds).
    /// - Returns: `true` if a valid double-tap Option gesture just completed.
    public mutating func feed(_ event: HotkeyInputEvent, at timestamp: TimeInterval) -> Bool {
        switch event {
        case .interruption:
            state = .idle
            return false

        case .optionDown:
            switch state {
            case .idle:
                state = .firstDown(startedAt: timestamp)
                return false

            case .firstDown, .secondDown:
                // Duplicate key-repeat or redundant flagsChanged while already held.
                return false

            case .awaitingSecondDown(let firstReleasedAt):
                if timestamp - firstReleasedAt <= maxDoubleTapInterval {
                    state = .secondDown(startedAt: timestamp)
                } else {
                    // Previous tap expired; treat this press as a fresh first tap.
                    state = .firstDown(startedAt: timestamp)
                }
                return false
            }

        case .optionUp:
            switch state {
            case .idle, .awaitingSecondDown:
                state = .idle
                return false

            case .firstDown(let startedAt):
                if timestamp - startedAt <= maxTapDuration {
                    state = .awaitingSecondDown(firstReleasedAt: timestamp)
                } else {
                    state = .idle
                }
                return false

            case .secondDown(let startedAt):
                state = .idle
                return (timestamp - startedAt) <= maxTapDuration
            }
        }
    }
}
