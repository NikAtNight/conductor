import XCTest
@testable import Conductor

final class HoldKeyTests: XCTestCase {
    let rightCommand = Shortcut(keyCode: 54, modifiers: 0)
    let dt = 1.0 / 30

    private func recognizer() -> GestureRecognizer {
        var map = GestureMap.standard
        map[.ringPinch] = .holdKey(rightCommand)
        return GestureRecognizer(config: .instant, map: map)
    }

    func testKeyIsHeldForExactlyAsLongAsThePinch() {
        var r = recognizer()
        XCTAssertEqual(r.update(hands: [PoseFixtures.pinched(.ringTip)], at: 0).actions, [.keyDown(rightCommand)])
        for i in 1...10 {
            XCTAssertEqual(r.update(hands: [PoseFixtures.pinched(.ringTip)], at: Double(i) * dt).actions, [])
        }
        XCTAssertEqual(r.update(hands: [PoseFixtures.openHand()], at: 11 * dt).actions, [.keyUp(rightCommand)])
    }

    func testLosingTheHandLetsGoOfTheKey() {
        var r = recognizer()
        _ = r.update(hands: [PoseFixtures.pinched(.ringTip)], at: 0)
        var actions: [GestureRecognizer.Action] = []
        for i in 1...14 { actions += r.update(hands: [], at: Double(i) * dt).actions }
        XCTAssertEqual(actions, [.keyUp(rightCommand)])
    }

    func testSwitchingProfilesLetsGoOfTheKey() {
        var r = recognizer()
        _ = r.update(hands: [PoseFixtures.pinched(.ringTip)], at: 0)
        XCTAssertEqual(r.replaceMap(.standard), [.keyUp(rightCommand)])
    }

    func testASwipeBoundToHoldKeyTapsIt() {
        var map = GestureMap.standard
        map[.swipeLeft] = .holdKey(rightCommand)
        map[.twoFingers] = .none // the pose would also scroll by palm travel
        var r = GestureRecognizer(config: .instant, map: map)
        var actions: [GestureRecognizer.Action] = []
        for i in 0...6 {
            let x = 0.35 + 0.25 * CGFloat(i) / 6
            actions += r.update(hands: [PoseFixtures.twoFingers(at: CGPoint(x: x, y: 0.3))], at: Double(i) * dt).actions
        }
        XCTAssertEqual(actions, [.keyDown(rightCommand), .keyUp(rightCommand)])
    }

    func testRightCommandCarriesTheDeviceBitWalkieChecks() {
        let down = InputController.flags(for: rightCommand, down: true)
        XCTAssertTrue(down.contains(.maskCommand))
        XCTAssertTrue(down.contains(CGEventFlags(rawValue: 0x10)), "NX_DEVICERCMDKEYMASK")
        XCTAssertFalse(down.contains(CGEventFlags(rawValue: 0x08)), "not the left command bit")
        XCTAssertTrue(InputController.flags(for: rightCommand, down: false).isEmpty)
    }

    func testRegularKeyKeepsItsModifiers() {
        let optionSpace = Shortcut(keyCode: 49, modifiers: CGEventFlags.maskAlternate.rawValue)
        XCTAssertEqual(InputController.flags(for: optionSpace, down: true), .maskAlternate)
        XCTAssertNil(InputController.modifier(for: 49))
    }

    @MainActor
    func testHoldKeyRoundTripsAndOldMapsStillLoad() throws {
        let suite = try XCTUnwrap(UserDefaults(suiteName: "HoldKeyTests.\(UUID())"))
        Preferences(defaults: suite).settings.gestureMap[.ringPinch] = .holdKey(rightCommand)
        XCTAssertEqual(Preferences(defaults: suite).settings.gestureMap[.ringPinch], .holdKey(rightCommand))
        XCTAssertEqual(GestureAction.holdKey(rightCommand).title, "Hold Right ⌘")
        XCTAssertEqual(GestureAction.holdKey(rightCommand).kind, .holdKey(GestureAction.unsetKey))
    }
}
