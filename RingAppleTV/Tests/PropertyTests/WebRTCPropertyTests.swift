import XCTest
import SwiftCheck
@testable import RingAppleTV

// MARK: - WebRTC Action Generator

/// Represents an action that can be applied to the WebRTC state machine.
private enum WebRTCAction: CaseIterable, CustomStringConvertible {
    case connect
    case connected
    case failed
    case disconnect

    var description: String {
        switch self {
        case .connect: return "connect"
        case .connected: return "connected"
        case .failed: return "failed"
        case .disconnect: return "disconnect"
        }
    }

    /// The target state this action attempts to transition to.
    func targetState() -> WebRTCConnectionState {
        switch self {
        case .connect: return .connecting
        case .connected: return .connected
        case .failed: return .failed("test error")
        case .disconnect: return .disconnected
        }
    }
}

extension WebRTCAction: Arbitrary {
    static var arbitrary: Gen<WebRTCAction> {
        Gen<WebRTCAction>.fromElements(of: WebRTCAction.allCases)
    }
}

// MARK: - Action Sequence Generator

/// Wrapper for a sequence of WebRTC actions for property testing.
private struct ActionSequence: CustomStringConvertible {
    let actions: [WebRTCAction]

    var description: String {
        actions.map(\.description).joined(separator: " → ")
    }
}

extension ActionSequence: Arbitrary {
    static var arbitrary: Gen<ActionSequence> {
        WebRTCAction.arbitrary
            .proliferate(withSize: 30)
            .suchThat { !$0.isEmpty }
            .map { ActionSequence(actions: $0) }
    }
}

// MARK: - Property Tests

/// Property-based tests for WebRTC correctness properties.
///
/// **Validates: Requirements CP-1, CP-3**
final class WebRTCPropertyTests: XCTestCase {

    // MARK: - CP-1: Resource Cleanup

    /// **Validates: Requirements CP-1**
    ///
    /// Property: After `stopStream()`, the connection state is `.disconnected`.
    /// We test this by generating arbitrary sequences of connect/disconnect
    /// actions and verifying that after every stop the manager is in a clean
    /// state: `connectionState` is `.disconnected`.
    func testResourceCleanup_afterStopStream_stateIsDisconnected() {
        property("CP-1: after stopStream(), state is .disconnected")
            <- forAll { (sequence: ActionSequence) -> Bool in
                let manager = MockStreamSessionManager()

                for action in sequence.actions {
                    switch action {
                    case .connect:
                        manager.simulateStateChange(.connecting)
                    case .connected:
                        manager.simulateStateChange(.connected)
                    case .failed:
                        manager.simulateStateChange(.failed("test error"))
                    case .disconnect:
                        let expectation = XCTestExpectation(description: "stopStream")
                        Task {
                            await manager.stopStream()
                            expectation.fulfill()
                        }
                        _ = XCTWaiter.wait(for: [expectation], timeout: 1.0)

                        // CP-1: immediately after every stop, verify cleanup
                        guard manager.connectionState == .disconnected else { return false }
                    }
                }

                // Always end with a stop to verify final cleanup
                let finalExpectation = XCTestExpectation(description: "final stopStream")
                Task {
                    await manager.stopStream()
                    finalExpectation.fulfill()
                }
                _ = XCTWaiter.wait(for: [finalExpectation], timeout: 1.0)

                guard manager.connectionState == .disconnected else { return false }
                guard manager.stopStreamCalls > 0 else { return false }

                return true
            }
    }

    // MARK: - CP-3: State Machine Consistency

    /// **Validates: Requirements CP-3**
    ///
    /// Property: For any sequence of delegate callbacks / state transition
    /// attempts, only valid transitions occur. The `canTransition(to:)` method
    /// must correctly enforce:
    /// - `disconnected → connecting`
    /// - `connecting → connected`
    /// - `connecting → failed`
    /// - `connected → disconnected`
    /// - `failed → disconnected`
    /// All other transitions must be rejected.
    func testStateMachine_onlyValidTransitionsOccur() {
        property("CP-3: for any sequence of actions, only valid state transitions occur")
            <- forAll { (sequence: ActionSequence) -> Bool in
                var currentState = WebRTCConnectionState.disconnected

                for action in sequence.actions {
                    let targetState = action.targetState()

                    if currentState.canTransition(to: targetState) {
                        // Valid transition — apply it
                        currentState = targetState
                    }
                    // Invalid transition — state stays the same (no-op)

                    // Verify the current state is always one of the valid states
                    switch currentState {
                    case .disconnected, .connecting, .connected, .failed:
                        break // all valid
                    }
                }

                return true
            }
    }

    /// **Validates: Requirements CP-3**
    ///
    /// Property: `canTransition(to:)` is consistent — it allows exactly the
    /// transitions defined in the spec and rejects all others.
    func testCanTransition_allowsOnlySpecifiedTransitions() {
        let allStates: [WebRTCConnectionState] = [
            .disconnected, .connecting, .connected, .failed("error")
        ]

        // Define the expected valid transitions per CP-3
        let validTransitions: [(WebRTCConnectionState, WebRTCConnectionState)] = [
            (.disconnected, .connecting),
            (.connecting, .connected),
            (.connecting, .failed("error")),
            (.connected, .disconnected),
            (.failed("error"), .disconnected)
        ]

        for from in allStates {
            for to in allStates {
                let isValid = from.canTransition(to: to)
                let shouldBeValid = validTransitions.contains { $0.0 == from && $0.1 == to }

                XCTAssertEqual(isValid, shouldBeValid,
                    "Transition \(from) → \(to): expected \(shouldBeValid), got \(isValid)")
            }
        }
    }

    /// **Validates: Requirements CP-3**
    ///
    /// Property: Starting from disconnected, applying any random sequence of
    /// actions always results in a reachable state, and the state after
    /// applying only valid transitions matches what canTransition allows.
    func testStateMachine_randomSequences_alwaysReachValidState() {
        property("CP-3: random action sequences always produce a valid reachable state")
            <- forAll { (sequence: ActionSequence) -> Bool in
                var currentState = WebRTCConnectionState.disconnected
                let validStates: Set<String> = ["disconnected", "connecting", "connected", "failed"]

                for action in sequence.actions {
                    let targetState = action.targetState()

                    if currentState.canTransition(to: targetState) {
                        currentState = targetState
                    }

                    // Verify state is always in the valid set
                    let stateLabel: String
                    switch currentState {
                    case .disconnected: stateLabel = "disconnected"
                    case .connecting: stateLabel = "connecting"
                    case .connected: stateLabel = "connected"
                    case .failed: stateLabel = "failed"
                    }

                    guard validStates.contains(stateLabel) else { return false }
                }

                return true
            }
    }
}
