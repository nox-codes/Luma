import XCTest
@testable import Luma

final class LumaCompanionSystemTests: XCTestCase {

    func testReducerMapsRuntimeEventsToVisibleStates() {
        XCTAssertEqual(LumaCompanionReducer.reduce(.idle, event: .listening), .listening)
        XCTAssertEqual(LumaCompanionReducer.reduce(.listening, event: .thinking), .thinking)
        XCTAssertEqual(
            LumaCompanionReducer.reduce(
                .thinking,
                event: .working(CompanionProgress(completed: 2, total: 5, label: "Inspecting"))
            ),
            .working(CompanionProgress(completed: 2, total: 5, label: "Inspecting"))
        )
    }

    func testReducerKeepsFailureAndAttentionDistinctFromSuccess() {
        let failure = LumaCompanionReducer.reduce(.working(progress: nil), event: .failed(message: "Verification failed"))
        let attention = LumaCompanionReducer.reduce(.working(progress: nil), event: .needsAttention(message: "Confirm this action"))

        XCTAssertEqual(failure, .failed(message: "Verification failed"))
        XCTAssertEqual(attention, .needsAttention(message: "Confirm this action"))
        XCTAssertNotEqual(failure, .success)
        XCTAssertNotEqual(attention, .success)
    }

    func testProgressClampsToValidFraction() {
        XCTAssertEqual(CompanionProgress(completed: 2, total: 5, label: nil).fraction, 0.4)
        XCTAssertEqual(CompanionProgress(completed: 8, total: 5, label: nil).fraction, 1.0)
        XCTAssertEqual(CompanionProgress(completed: -1, total: 5, label: nil).fraction, 0.0)
        XCTAssertEqual(CompanionProgress(completed: 0, total: 0, label: nil).fraction, 0.0)
    }

    func testWorkingStateExplainsProgressWhenStepHasNoLabel() {
        let system = LumaCompanionSystem(defaults: UserDefaults(suiteName: #function)!)
        system.send(.working(CompanionProgress(completed: 2, total: 5)))

        XCTAssertEqual(system.stateExplanation, "40% complete")
    }

    func testLegacyBubbleSettingsBecomeCharacterAppearance() {
        let appearance = CompanionAppearance.fromLegacy(
            styleRawValue: "spectrum",
            bubbleSize: 80,
            opacity: 0.7
        )

        XCTAssertEqual(appearance.preset, .focus)
        XCTAssertEqual(appearance.scale, 1.25, accuracy: 0.001)
        XCTAssertEqual(appearance.opacity, 0.7, accuracy: 0.001)
        XCTAssertEqual(appearance.motion.intensity, 0.7, accuracy: 0.001)
    }

    func testAppearanceValuesAreBounded() {
        var appearance = CompanionAppearance.default
        appearance.scale = 4
        appearance.opacity = -1
        appearance.motion.intensity = 2

        let bounded = appearance.bounded

        XCTAssertEqual(bounded.scale, 1.5, accuracy: 0.001)
        XCTAssertEqual(bounded.opacity, 0.0, accuracy: 0.001)
        XCTAssertEqual(bounded.motion.intensity, 1.0, accuracy: 0.001)
    }
}
