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
                              tweak: (inout Preferences.Snapshot) -> Void = { _ in }) -> FramePipeline {
        var snapshot = Preferences(defaults: UserDefaults(suiteName: "FramePipelineTests.\(UUID())")!).snapshot
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

    func testAFistFlickScrollsThenCoastsThenStopsOnAClick() {
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
        pipeline = makePipeline(map: map)
        for i in 0..<6 { frame([PoseFixtures.fist(at: CGPoint(x: 0.5, y: 0.3 + 0.02 * CGFloat(i)))]) }
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
        let snapshot = Preferences(defaults: UserDefaults(suiteName: "FramePipelineTests.\(UUID())")!).snapshot
        XCTAssertEqual(pipeline.apply(snapshot, map: map, displays: [screen], cameraMount: nil), [.leftUp(clickCount: 1)])
    }

    // MARK: Look mode

    let top = CGRect(x: 0, y: 0, width: 1000, height: 500)
    let bottom = CGRect(x: 0, y: 500, width: 1000, height: 500)

    /// Two stacked displays and a model that puts the top one at pitch 0...5 and the bottom at
    /// 10...15. The face fixture's box is 0.4 tall, so the model's distance matches it.
    private func makeLookPipeline() -> FramePipeline {
        let model = LookModel(targets: [
            LookModel.Target(displayUUID: "top", pitch: 0...5, yaw: -10...10),
            LookModel.Target(displayUUID: "bottom", pitch: 10...15, yaw: -10...10),
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

    func testTheControlBoxFollowsTheSettings() {
        let before = pipeline.box
        var snapshot = Preferences(defaults: UserDefaults(suiteName: "FramePipelineTests.\(UUID())")!).snapshot
        snapshot.boxWidth = 0.3
        _ = pipeline.apply(snapshot, map: .standard, displays: [screen], cameraMount: nil)
        XCTAssertLessThan(pipeline.box.width, before.width)
    }
}
