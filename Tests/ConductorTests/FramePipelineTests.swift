import XCTest
@testable import Conductor

/// The whole frame, with the shipped settings: what the Engine posts for a stream of hands.
@MainActor
final class FramePipelineTests: XCTestCase {
    typealias Command = InputCommand
    let dt = 1.0 / 30
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 1000)
    var pipeline: FramePipeline!
    var t = 0.0
    var commands: [Command] = []
    var last: FramePipeline.Output?

    override func setUp() {
        super.setUp()
        pipeline = makePipeline()
    }

    /// Production defaults, except that taking control isn't the point of most tests here.
    private func makePipeline(map: GestureMap = .standard, requireReadyPose: Bool = false,
                              displays: [String: CGRect]? = nil,
                              tweak: (inout Settings) -> Void = { _ in }) -> FramePipeline {
        var snapshot = Settings()
        snapshot.requireReadyPose = requireReadyPose
        tweak(&snapshot)
        var p = FramePipeline(snapshot)
        _ = p.apply(snapshot, map: map, displays: displays.map { Array($0.values) } ?? [screen], cameraMount: nil,
                    lookDisplays: displays ?? [:])
        _ = p.setInputAllowed(true)
        return p
    }

    private func frame(_ hands: [HandPose], face: FacePose? = nil, count: Int = 1) {
        for _ in 0..<count {
            last = pipeline.step(hands: hands, face: face, at: t) { CGPoint(x: 500, y: 500) }
            commands += last!.commands
            t += dt
        }
    }

    private var scrolls: [Int32] {
        commands.compactMap { if case .scroll(let dy, let flags) = $0, flags.isEmpty { return dy } else { return nil } }
    }
    private var moves: [CGPoint] {
        commands.compactMap { if case .move(let p) = $0 { return p } else { return nil } }
    }

    func testAnOpenHandMovesTheCursorInsideTheScreen() {
        for i in 0..<10 { frame([PoseFixtures.openHand(at: CGPoint(x: 0.5 - 0.02 * CGFloat(i), y: 0.3))]) }
        XCTAssertGreaterThan(moves.count, 3)
        XCTAssertTrue(moves.allSatisfy { screen.contains($0) })
        XCTAssertTrue(zip(moves, moves.dropFirst()).allSatisfy { $1.x > $0.x }, "mirrored: hand to Vision's left is the user's right")
        XCTAssertEqual(commands.count, moves.count, "nothing but moves")
    }

    func testAPinchClicksAfterTheShippedHold() {
        frame([PoseFixtures.openHand()])
        frame([PoseFixtures.pinched()], count: 2)
        XCTAssertFalse(commands.contains(.leftDown(clickCount: 1)))
        frame([PoseFixtures.pinched()])
        XCTAssertTrue(commands.contains(.leftDown(clickCount: 1)))
        frame([PoseFixtures.openHand()])
        XCTAssertTrue(commands.contains(.leftUp(clickCount: 1)))
    }

    func testAFistHeldAboveWhereItClosedScrollsUntilItOpensAndNeverCoasts() {
        frame([PoseFixtures.openHand()])
        frame([PoseFixtures.fist()], count: 2)
        XCTAssertEqual(scrolls, [], "at neutral: nothing")
        frame([PoseFixtures.fist(at: CGPoint(x: 0.5, y: 0.36))], count: 10)
        XCTAssertGreaterThanOrEqual(scrolls.count, 9, "a steady rate while held off centre")
        XCTAssertTrue(scrolls.allSatisfy { $0 < 0 }, "hand up scrolls content up: negative wheel")
        commands = []
        frame([PoseFixtures.openHand(at: CGPoint(x: 0.5, y: 0.36))], count: 10)
        XCTAssertEqual(scrolls, [], "letting go stops at once")
        frame([PoseFixtures.openHand()], count: 3)
        XCTAssertEqual(scrolls, [], "bringing the hand back scrolls nothing")
    }

    func testAFistFlickScrollsThenCoastsThenStopsOnAClick() {
        pipeline = makePipeline { $0.scrollStyle = .travel }
        frame([PoseFixtures.openHand()])
        for i in 0..<6 { frame([PoseFixtures.fist(at: CGPoint(x: 0.5, y: 0.3 + 0.02 * CGFloat(i)))]) }
        let live = scrolls
        XCTAssertFalse(live.isEmpty)
        XCTAssertTrue(live.allSatisfy { $0 < 0 }, "hand up scrolls content up: negative wheel")
        commands = []
        frame([PoseFixtures.openHand(at: CGPoint(x: 0.5, y: 0.4))], count: 5)
        XCTAssertGreaterThan(scrolls.count, 3, "coasting after the hand lets go")
        commands = []
        frame([PoseFixtures.pinched(at: CGPoint(x: 0.5, y: 0.4))], count: 3)
        XCTAssertTrue(commands.contains(.leftDown(clickCount: 1)))
        commands = []
        frame([PoseFixtures.openHand(at: CGPoint(x: 0.5, y: 0.4))], count: 5)
        XCTAssertEqual(scrolls, [], "a click ends the coast")
    }

    func testAGesturePauseStopsCoasting() {
        var map = GestureMap.standard
        map[.littlePinch] = .pauseTracking
        // The travel style, since only it coasts.
        pipeline = makePipeline(map: map) { $0.scrollStyle = .travel }
        frame([PoseFixtures.openHand()])
        for i in 0..<6 { frame([PoseFixtures.fist(at: CGPoint(x: 0.5, y: 0.3 + 0.02 * CGFloat(i)))]) }
        commands = []
        frame([PoseFixtures.openHand(at: CGPoint(x: 0.5, y: 0.4))]) // fingers must open after the fist
        XCTAssertFalse(scrolls.isEmpty, "coasting before the pause")
        frame([PoseFixtures.pinched(.littleTip, at: CGPoint(x: 0.5, y: 0.4))], count: 3)
        XCTAssertEqual(last?.recognized.mode, .paused)
        commands = []
        frame([PoseFixtures.pinched(.littleTip, at: CGPoint(x: 0.5, y: 0.4))], count: 10)
        XCTAssertEqual(commands, [], "nothing scrolls while paused")
    }

    func testZoomKeyStepsDoNotCarryOverBetweenGestures() {
        pipeline = makePipeline { $0.zoomWithKeys = true }
        func spread(_ d: CGFloat) -> [HandPose] {
            [PoseFixtures.pinched(at: CGPoint(x: 0.3, y: 0.3)), PoseFixtures.pinched(at: CGPoint(x: 0.6 + d, y: 0.3))]
        }
        for i in 0..<6 { frame(spread(0.005 * CGFloat(i))) } // 0.025 total, under the 0.04 step
        frame([PoseFixtures.openHand()], count: 3)
        for i in 0..<6 { frame(spread(0.005 * CGFloat(i))) }
        XCTAssertFalse(commands.contains(.keyPress(KeyCodes.equals, flags: .maskCommand)))
    }

    func testLosingAccessibilityReleasesWhatIsHeldOnEveryPath() {
        frame([PoseFixtures.pinched()], count: 3)
        XCTAssertTrue(commands.contains(.leftDown(clickCount: 1)))
        let released = pipeline.setInputAllowed(false)
        XCTAssertTrue(released.contains(.leftUp(clickCount: 1)))
        XCTAssertEqual(released.last, .releaseAll)
        commands = []
        frame([PoseFixtures.openHand()], count: 5)
        XCTAssertEqual(commands, [], "nothing is posted without the grant")
        XCTAssertEqual(pipeline.setInputAllowed(true), [])
        frame([PoseFixtures.openHand(at: CGPoint(x: 0.45, y: 0.3))], count: 3)
        XCTAssertFalse(moves.isEmpty, "moves resume with the grant")
    }

    func testAStallReleaseKeepsControl() {
        pipeline = makePipeline(requireReadyPose: true)
        frame([PoseFixtures.openHand()], count: 20)
        XCTAssertEqual(last?.recognized.mode, .point)
        frame([PoseFixtures.pinched()], count: 3)
        XCTAssertEqual(pipeline.releaseHeld(), [.leftUp(clickCount: 1), .releaseAll])
        commands = []
        frame([PoseFixtures.openHand(at: CGPoint(x: 0.45, y: 0.3))], count: 3)
        XCTAssertEqual(last?.recognized.mode, .point, "no ready pose needed again")
        XCTAssertFalse(moves.isEmpty)
    }

    func testAStallCannotTurnARestingHandIntoADwellClick() {
        pipeline = makePipeline { $0.dwellClick = true }
        frame([PoseFixtures.openHand()], count: 10)
        _ = pipeline.releaseHeld()
        t += 1.2 // the stall
        commands = []
        frame([PoseFixtures.openHand()], count: 3)
        XCTAssertFalse(commands.contains(where: \.isClick))
    }

    func testRebindingReleasesAHeldButton() {
        frame([PoseFixtures.pinched()], count: 3)
        var map = GestureMap.standard
        map[.indexPinch] = .rightClick
        XCTAssertEqual(pipeline.apply(Settings(), map: map, displays: [screen], cameraMount: nil), [.leftUp(clickCount: 1)])
    }

    // MARK: Look mode

    let top = CGRect(x: 0, y: 0, width: 1000, height: 500)
    let bottom = CGRect(x: 0, y: 500, width: 1000, height: 500)

    /// Two stacked displays and a model that puts the top one around pitch 2.5 and the bottom around
    /// 12.5. The face fixture's box is 0.4 tall, so the model's distance matches it.
    private func makeLookPipeline() -> FramePipeline {
        let yaw = LookModel.Spread(mean: 0, sd: 3)
        let model = LookModel(targets: [
            LookModel.Target(displayUUID: "top", pitch: LookModel.Spread(mean: 2.5, sd: 1.5), yaw: yaw),
            LookModel.Target(displayUUID: "bottom", pitch: LookModel.Spread(mean: 12.5, sd: 1.5), yaw: yaw),
        ], faceHeight: 0.4)
        return makePipeline(displays: ["top": top, "bottom": bottom]) {
            $0.displayMode = .lookedAt
            $0.lookModel = model
        }
    }

    /// A hand drifting a little each frame, so every frame posts a move.
    private func drifting(_ face: FacePose, count: Int) {
        for _ in 0..<count {
            frame([PoseFixtures.openHand(at: CGPoint(x: 0.5 - 0.01 * CGFloat(t / dt), y: 0.3))], face: face)
        }
    }

    func testLookingAtTheOtherDisplayMovesTheBoxThereAfterTheDwell() {
        pipeline = makeLookPipeline()
        drifting(FaceFixtures.face(pitchDegrees: 2), count: 5)
        XCTAssertEqual(pipeline.screen, top)
        XCTAssertGreaterThan(moves.count, 2)
        XCTAssertTrue(moves.allSatisfy { top.contains($0) })
        commands = []
        drifting(FaceFixtures.face(pitchDegrees: 12), count: 2) // under the dwell
        XCTAssertEqual(pipeline.screen, top, "a glance isn't enough")
        XCTAssertTrue(moves.allSatisfy { top.contains($0) })
        commands = []
        drifting(FaceFixtures.face(pitchDegrees: 12), count: Int(LookPicker.dwell / dt) + 3)
        XCTAssertEqual(pipeline.screen, bottom)
        XCTAssertTrue(bottom.contains(moves.last!))
        XCTAssertTrue(moves.suffix(3).allSatisfy { bottom.contains($0) })
    }

    func testAHeldPinchKeepsTheBoxOnItsDisplayUntilItReleases() {
        pipeline = makeLookPipeline()
        drifting(FaceFixtures.face(pitchDegrees: 2), count: 5)
        frame([PoseFixtures.pinched()], count: 3)
        XCTAssertTrue(commands.contains(.leftDown(clickCount: 1)))
        commands = []
        frame([PoseFixtures.pinched()], face: FaceFixtures.face(pitchDegrees: 12), count: Int(LookPicker.dwell / dt) + 5)
        XCTAssertEqual(pipeline.screen, top, "no switch while the button is down")
        XCTAssertTrue(moves.allSatisfy { top.contains($0) })
        frame([PoseFixtures.openHand()], face: FaceFixtures.face(pitchDegrees: 12), count: 2)
        XCTAssertTrue(commands.contains(.leftUp(clickCount: 1)))
        XCTAssertEqual(pipeline.screen, bottom, "the dwell already passed, so the release lets it switch")
    }

    func testInLookModeTheBoxStaysPutWhenTheDisplayChanges() {
        pipeline = makeLookPipeline()
        drifting(FaceFixtures.face(pitchDegrees: 2), count: 5)
        let onTop = pipeline.box
        XCTAssertEqual(onTop.midX, 0.5, accuracy: 1e-9, "centred, not shifted toward a camera")
        drifting(FaceFixtures.face(pitchDegrees: 12), count: Int(LookPicker.dwell / dt) + 3)
        XCTAssertEqual(pipeline.screen, bottom)
        XCTAssertEqual(pipeline.box, onTop, "the head picked the screen; the hand shouldn't have to reach for it")
    }

    // MARK: Switch display

    /// The shipped pointing hold, with a frame to spare, then the hand opens.
    private func point(_ direction: Direction, face: FacePose? = nil) {
        frame([PoseFixtures.pointingSign(direction)], face: face, count: 11)
        frame([PoseFixtures.openHand()], face: face, count: 2)
    }

    func testPointingDownSwitchesToTheDisplayBelowAndTheHeadDoesNotUndoIt() {
        pipeline = makeLookPipeline()
        let atTop = FaceFixtures.face(pitchDegrees: 2)
        drifting(atTop, count: 5)
        XCTAssertEqual(pipeline.screen, top)
        frame([PoseFixtures.pointingSign(.down)], face: atTop, count: 11)
        XCTAssertEqual(pipeline.screen, bottom, "no look dwell, just the sign's hold")
        frame([PoseFixtures.pointingSign(.down)], face: atTop, count: 20)
        XCTAssertEqual(pipeline.screen, bottom, "one switch per sign")
        commands = []
        drifting(atTop, count: Int(4 * LookPicker.dwell / dt))
        XCTAssertEqual(pipeline.screen, bottom, "still facing the old display doesn't switch back")
        XCTAssertTrue(moves.suffix(3).allSatisfy { bottom.contains($0) })
    }

    func testPointingWhereThereIsNoDisplayGoesToTheNextOne() {
        pipeline = makeLookPipeline()
        let atTop = FaceFixtures.face(pitchDegrees: 2)
        drifting(atTop, count: 5)
        point(.up, face: atTop)
        XCTAssertEqual(pipeline.screen, bottom, "nothing above the top display: the other one")
        point(.left, face: atTop)
        XCTAssertEqual(pipeline.screen, top, "nothing beside either: wraps around")
    }

    func testAfterASwitchTurningTheHeadAwayAndBackPicksByHeadAgain() {
        pipeline = makeLookPipeline()
        let atTop = FaceFixtures.face(pitchDegrees: 2), atBottom = FaceFixtures.face(pitchDegrees: 12)
        drifting(atTop, count: 5)
        point(.down, face: atTop)
        XCTAssertEqual(pipeline.screen, bottom)
        drifting(atBottom, count: Int(LookPicker.dwell / dt) + 3)
        XCTAssertEqual(pipeline.screen, bottom)
        drifting(atTop, count: 2)
        XCTAssertEqual(pipeline.screen, bottom, "the dwell still applies")
        drifting(atTop, count: Int(LookPicker.dwell / dt) + 3)
        XCTAssertEqual(pipeline.screen, top)
    }

    func testSwitchDisplayDoesNothingAcrossAllDisplays() {
        pipeline = makePipeline(displays: ["top": top, "bottom": bottom])
        let screen = pipeline.screen, box = pipeline.box
        frame([PoseFixtures.openHand()])
        point(.down)
        XCTAssertEqual(pipeline.screen, screen)
        XCTAssertEqual(pipeline.box, box)
        XCTAssertTrue(commands.allSatisfy { if case .move = $0 { return true } else { return false } })
    }

    func testFollowCursorSwitchesAndWrapsOnlyWithInputAllowed() {
        pipeline = makePipeline(displays: ["top": top, "bottom": bottom]) { $0.displayMode = .followCursor }
        frame([PoseFixtures.openHand()])
        XCTAssertEqual(pipeline.screen, bottom, "the cursor at 500, 500 sits on the bottom display")
        _ = pipeline.setInputAllowed(false)
        point(.up)
        XCTAssertEqual(pipeline.screen, bottom, "skipped like any other action")
        _ = pipeline.setInputAllowed(true)
        point(.up)
        XCTAssertEqual(pipeline.screen, top)
        point(.up)
        XCTAssertEqual(pipeline.screen, bottom, "nothing above: wraps from the first display to the last")
    }

    func testTheDirectionPicksTheNearestDisplayThatWay() {
        let left = CGRect(x: -1000, y: 0, width: 1000, height: 500)
        let farLeft = CGRect(x: -2000, y: 0, width: 1000, height: 500)
        let all = [top, bottom, left, farLeft]
        XCTAssertEqual(FramePipeline.display(from: top, toward: .down, in: all), bottom)
        XCTAssertEqual(FramePipeline.display(from: bottom, toward: .up, in: all), top)
        XCTAssertEqual(FramePipeline.display(from: top, toward: .left, in: all), left, "the nearest, not the furthest")
        XCTAssertEqual(FramePipeline.display(from: left, toward: .right, in: all), top)
        XCTAssertNil(FramePipeline.display(from: top, toward: .up, in: all))
        XCTAssertNil(FramePipeline.display(from: top, toward: .right, in: all))
        XCTAssertEqual(FramePipeline.display(from: bottom, toward: .left, in: all), left, "more left than up from bottom")
        XCTAssertNil(FramePipeline.display(from: left, toward: .down, in: all), "bottom is more right than down from left")
    }

    func testTheControlBoxFollowsTheSettings() {
        let before = pipeline.box
        var snapshot = Settings()
        snapshot.boxWidth = 0.3
        _ = pipeline.apply(snapshot, map: .standard, displays: [screen], cameraMount: nil)
        XCTAssertLessThan(pipeline.box.width, before.width)
    }
}
