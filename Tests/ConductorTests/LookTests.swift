import XCTest
@testable import Conductor

final class LookCalibrationTests: XCTestCase {
    let top = "top"
    let bottom = "bottom"

    /// `count` samples spread evenly across the pitch and yaw ranges, in degrees.
    private func samples(_ display: String, pitch: ClosedRange<Double>, yaw: ClosedRange<Double> = -10...10,
                         count: Int = 20, height: (Int) -> Double = { _ in 0.4 }) -> [LookCalibration.Sample] {
        (0..<count).map { i in
            let t = Double(i) / Double(count - 1)
            return LookCalibration.Sample(displayUUID: display,
                                          pitch: pitch.lowerBound + t * (pitch.upperBound - pitch.lowerBound),
                                          yaw: yaw.lowerBound + t * (yaw.upperBound - yaw.lowerBound),
                                          faceHeight: height(i))
        }
    }

    func testTwoStackedDisplaysWithDistinctAnglesCalibrate() throws {
        let all = samples(top, pitch: 3...7) + samples(bottom, pitch: 10...14)
        let model = try LookCalibration.pass(from: all, displays: [top, bottom]).get()
        XCTAssertEqual(model.targets.map(\.displayUUID), [top, bottom])
        XCTAssertTrue((3.0...7.0).contains(model.targets[0].pitch.lowerBound))
        XCTAssertTrue((10.0...14.0).contains(model.targets[1].pitch.lowerBound))
    }

    func testAStrayFrameDoesNotStretchTheTargetBecauseOfPercentileTrimming() throws {
        let outlier = LookCalibration.Sample(displayUUID: top, pitch: 40, yaw: 0, faceHeight: 0.4)
        let all = samples(top, pitch: 3...7) + [outlier] + samples(bottom, pitch: 10...14)
        let model = try LookCalibration.pass(from: all, displays: [top, bottom]).get()
        let pitch = model.targets[0].pitch
        XCTAssertGreaterThanOrEqual(pitch.lowerBound, 3)
        XCTAssertLessThanOrEqual(pitch.upperBound, 7)
    }

    func testTargetYawCoversTheSampledAnglesLessTheTrimmedTails() throws {
        let all = samples(top, pitch: 3...7) + samples(bottom, pitch: 10...14)
        let yaw = try LookCalibration.pass(from: all, displays: [top, bottom]).get().targets[0].yaw
        XCTAssertGreaterThanOrEqual(yaw.lowerBound, -10)
        XCTAssertLessThan(yaw.lowerBound, -8)
        XCTAssertLessThanOrEqual(yaw.upperBound, 10)
        XCTAssertGreaterThan(yaw.upperBound, 8)
    }

    func testModelFaceHeightIsTheMedianOfAllSamples() throws {
        // 41 samples with heights 0.30...0.49, so the middle one is 0.40.
        let all = samples(top, pitch: 3...7, count: 20, height: { 0.30 + 0.01 * Double($0) })
            + samples(bottom, pitch: 10...14, count: 21, height: { 0.30 + 0.01 * Double($0) })
        let model = try LookCalibration.pass(from: all, displays: [top, bottom]).get()
        XCTAssertEqual(model.faceHeight, 0.40, accuracy: 1e-9)
    }

    func testTooFewSamplesForOneDisplayNamesThatDisplay() {
        let few = LookCalibration.minimumSamplesPerDisplay - 1
        let all = samples(top, pitch: 3...7) + samples(bottom, pitch: 10...14, count: few)
        let result = LookCalibration.pass(from: all, displays: [top, bottom])
        XCTAssertEqual(result, .failure(.tooFewSamples(displayUUID: bottom)))
    }

    func testExactlyTheMinimumSampleCountIsEnough() throws {
        let enough = LookCalibration.minimumSamplesPerDisplay
        let all = samples(top, pitch: 3...7, count: enough) + samples(bottom, pitch: 10...14, count: enough)
        _ = try LookCalibration.pass(from: all, displays: [top, bottom]).get()
    }

    func testADisplayWithNoSamplesAtAllIsTooFew() {
        let result = LookCalibration.pass(from: samples(top, pitch: 3...7), displays: [top, bottom])
        XCTAssertEqual(result, .failure(.tooFewSamples(displayUUID: bottom)))
    }

    func testDisplaysWhoseSamplesCoverTheSameAnglesAreIndistinct() {
        let all = samples(top, pitch: 3...7) + samples(bottom, pitch: 3...7)
        let result = LookCalibration.pass(from: all, displays: [top, bottom])
        XCTAssertEqual(result, .failure(.indistinct(top, bottom)))
    }

    func testSampleConvertsRadiansToDegreesAndKeepsFaceHeight() throws {
        let face = FaceFixtures.face(pitchDegrees: 12, yawDegrees: -7, faceHeight: 0.35)
        let sample = try XCTUnwrap(LookCalibration.sample(face, display: top))
        XCTAssertEqual(sample.displayUUID, top)
        XCTAssertEqual(sample.pitch, 12, accuracy: 1e-9)
        XCTAssertEqual(sample.yaw, -7, accuracy: 1e-9)
        XCTAssertEqual(sample.faceHeight, 0.35, accuracy: 1e-9)
    }

    func testSampleIsNilWhenPitchIsMissing() {
        var face = FaceFixtures.face(pitchDegrees: 5)
        face.pitch = nil
        XCTAssertNil(LookCalibration.sample(face, display: top))
    }

    func testSampleIsNilWhenYawIsMissing() {
        var face = FaceFixtures.face(pitchDegrees: 5)
        face.yaw = nil
        XCTAssertNil(LookCalibration.sample(face, display: top))
    }
}

final class LookPickerTests: XCTestCase {
    let top = "top"
    let bottom = "bottom"

    /// Frames arrive at 30 fps; frame `n` is at n / 30 seconds.
    private let fps = 30.0
    private func time(_ frame: Int) -> TimeInterval { Double(frame) / fps }
    /// Dwell is 0.25 s, which is 7.5 frames. A candidate first seen at frame 1 has waited long
    /// enough at frame 1 + dwellFrames (8 frames later), and not yet at frame dwellFrames.
    private var dwellFrames: Int { Int((LookPicker.dwell * fps).rounded(.up)) }

    private func model(top topPitch: ClosedRange<Double> = 3...7, bottom bottomPitch: ClosedRange<Double> = 10...14,
                       faceHeight: Double = 0.4) -> LookModel {
        LookModel(targets: [LookModel.Target(displayUUID: top, pitch: topPitch, yaw: -10...10),
                            LookModel.Target(displayUUID: bottom, pitch: bottomPitch, yaw: -10...10)],
                  faceHeight: faceHeight)
    }

    /// Feeds the same face on each frame in `frames` and returns the last pick.
    @discardableResult
    private func feed(_ picker: inout LookPicker, _ face: FacePose?, frames: ClosedRange<Int>,
                      locked: Bool = false) -> String? {
        var pick: String?
        for frame in frames { pick = picker.update(face, at: time(frame), locked: locked) }
        return pick
    }

    /// A picker that settled on the bottom display at frame 0.
    private func pickerOnBottom(_ model: LookModel? = nil, faceHeight: Double = 0.4) -> LookPicker {
        var picker = LookPicker(model: model ?? self.model())
        _ = picker.update(FaceFixtures.face(pitchDegrees: 12, faceHeight: faceHeight), at: 0, locked: false)
        return picker
    }

    func testTheFirstFacePicksADisplayImmediately() {
        var picker = LookPicker(model: model())
        XCTAssertNil(picker.current)
        XCTAssertEqual(picker.update(FaceFixtures.face(pitchDegrees: 5), at: 0, locked: false), top)
        XCTAssertEqual(picker.current, top)
    }

    func testTheFirstFaceOutsideEveryTargetPicksTheNearest() {
        var picker = LookPicker(model: model())
        XCTAssertEqual(picker.update(FaceFixtures.face(pitchDegrees: 20), at: 0, locked: false), bottom)
    }

    func testAFaceWithoutAnglesBeforeAnyPickLeavesThePickNil() {
        var picker = LookPicker(model: model())
        var face = FaceFixtures.face(pitchDegrees: 5)
        face.yaw = nil
        XCTAssertNil(picker.update(face, at: 0, locked: false))
    }

    func testGlancingAtTheOtherDisplayForLessThanDwellKeepsThePick() {
        var picker = pickerOnBottom()
        let glance = FaceFixtures.face(pitchDegrees: 5)
        XCTAssertEqual(feed(&picker, glance, frames: 1...dwellFrames), bottom)
    }

    func testLookingAtTheOtherDisplayForDwellSwitchesThePick() {
        var picker = pickerOnBottom()
        let look = FaceFixtures.face(pitchDegrees: 5)
        XCTAssertEqual(feed(&picker, look, frames: 1...(1 + dwellFrames)), top)
        XCTAssertEqual(picker.current, top)
    }

    func testLookingBackBeforeDwellEndsCancelsTheSwitch() {
        var picker = pickerOnBottom()
        feed(&picker, FaceFixtures.face(pitchDegrees: 5), frames: 1...4)
        feed(&picker, FaceFixtures.face(pitchDegrees: 12), frames: 5...5)
        // Looking at top again starts a fresh dwell at frame 6.
        let look = FaceFixtures.face(pitchDegrees: 5)
        XCTAssertEqual(feed(&picker, look, frames: 6...(5 + dwellFrames)), bottom)
        XCTAssertEqual(feed(&picker, look, frames: (6 + dwellFrames)...(6 + dwellFrames)), top)
    }

    func testALockedInteractionBlocksTheSwitchEvenAfterDwell() {
        var picker = pickerOnBottom()
        let look = FaceFixtures.face(pitchDegrees: 5)
        // One second of looking at top while locked, well past dwell.
        XCTAssertEqual(feed(&picker, look, frames: 1...30, locked: true), bottom)
    }

    func testTheSwitchHappensOnceTheLockEndsIfTheCandidateIsStillThere() {
        var picker = pickerOnBottom()
        let look = FaceFixtures.face(pitchDegrees: 5)
        feed(&picker, look, frames: 1...30, locked: true)
        XCTAssertEqual(picker.update(look, at: time(31), locked: false), top)
    }

    func testAFaceBetweenTheTargetsDoesNotSwitchBecauseTheAdvantageIsUnderTheMargin() {
        // Targets cover pitch 0...5 and 7...12. At 6.3 degrees the first is 1.3 away and the second
        // 0.7 away: closer, but by 0.6, under the 1 degree margin.
        var picker = LookPicker(model: model(top: 0...5, bottom: 7...12))
        XCTAssertEqual(picker.update(FaceFixtures.face(pitchDegrees: 2), at: 0, locked: false), top)
        let between = FaceFixtures.face(pitchDegrees: 6.3)
        XCTAssertEqual(feed(&picker, between, frames: 1...30), top)
    }

    func testNoFaceReturnsTheCurrentPick() {
        var picker = pickerOnBottom()
        XCTAssertEqual(picker.update(nil, at: time(1), locked: false), bottom)
    }

    func testNoFaceBeforeAnyPickReturnsNil() {
        var picker = LookPicker(model: model())
        XCTAssertNil(picker.update(nil, at: 0, locked: false))
    }

    func testLosingTheFaceResetsTheCandidateSoTheNextGlanceRestartsItsDwell() {
        var picker = pickerOnBottom()
        let look = FaceFixtures.face(pitchDegrees: 5)
        // The glance is one frame short of dwell when the face drops out for a frame.
        feed(&picker, look, frames: 1...dwellFrames)
        XCTAssertEqual(picker.update(nil, at: time(dwellFrames + 1), locked: false), bottom)
        // The glance resumes; without the reset it would switch on the very next frame.
        let resume = dwellFrames + 2
        XCTAssertEqual(feed(&picker, look, frames: resume...(resume + dwellFrames - 1)), bottom)
        XCTAssertEqual(picker.update(look, at: time(resume + dwellFrames), locked: false), top)
    }

    func testACloserFaceScalesTheTargetsUpSoAHigherAngleStillCountsAsBottom() {
        // Calibrated at face height 0.3, bottom display at 10...14. At 0.45 (1.5x closer) the bottom
        // target spans about 14.8...20.5 degrees, so 16 is inside it.
        var picker = LookPicker(model: model(faceHeight: 0.3))
        XCTAssertEqual(picker.update(FaceFixtures.face(pitchDegrees: 5, faceHeight: 0.3), at: 0, locked: false), top)
        let closeAndLow = FaceFixtures.face(pitchDegrees: 16, faceHeight: 0.45)
        XCTAssertEqual(feed(&picker, closeAndLow, frames: 1...(1 + dwellFrames)), bottom)
    }

    func testACloserFaceAtAnAngleInsideTheRawBottomTargetReadsAsTop() {
        // Same calibration. Pitch 11 is inside the raw bottom range, but 1.5x closer the bottom
        // target starts near 14.8 and the top target (about 4.5...10.4) is the nearer one.
        var picker = pickerOnBottom(model(faceHeight: 0.3), faceHeight: 0.3)
        let close = FaceFixtures.face(pitchDegrees: 11, faceHeight: 0.45)
        XCTAssertEqual(feed(&picker, close, frames: 1...(1 + dwellFrames)), top)
    }

    func testScaledByRatioOneLeavesARangeUnchanged() {
        let scaled = LookModel.scaled(10...14, by: 1)
        XCTAssertEqual(scaled.lowerBound, 10, accuracy: 1e-9)
        XCTAssertEqual(scaled.upperBound, 14, accuracy: 1e-9)
    }

    func testScaledScalesTheTangentOfTheAngleByTheRatio() {
        let scaled = LookModel.scaled(10...14, by: 1.5)
        func expected(_ degrees: Double) -> Double { atan(tan(degrees * .pi / 180) * 1.5) * 180 / .pi }
        XCTAssertEqual(scaled.lowerBound, expected(10), accuracy: 1e-9)
        XCTAssertEqual(scaled.upperBound, expected(14), accuracy: 1e-9)
        XCTAssertGreaterThan(scaled.lowerBound, 10)
    }

    func testScaledKeepsTheRangeOrderedWhenTheAnglesAreNegative() {
        let scaled = LookModel.scaled(-14 ... -10, by: 1.5)
        XCTAssertLessThan(scaled.lowerBound, scaled.upperBound)
        XCTAssertLessThan(scaled.upperBound, -10)
    }
}

/// Passes per sitting distance, with the numbers from Nikhil's desk: up close the head sweeps
/// about 20 degrees per screen, further back only a few, so the two passes look nothing alike.
final class LookModelPassesTests: XCTestCase {
    let top = "top"
    let bottom = "bottom"
    let fps = 30.0

    /// Measured at face height 0.377 (close) and 0.25 (leaning back).
    var close: LookModel.Pass {
        LookModel.Pass(faceHeight: 0.377, targets: [
            LookModel.Target(displayUUID: top, pitch: -17.5...4.0, yaw: -26.6...20.6),
            LookModel.Target(displayUUID: bottom, pitch: 0.7...17.8, yaw: -10.2...19.8),
        ])
    }
    var far: LookModel.Pass {
        LookModel.Pass(faceHeight: 0.25, targets: [
            LookModel.Target(displayUUID: top, pitch: 5.0...6.5, yaw: -3...3),
            LookModel.Target(displayUUID: bottom, pitch: 7.5...9.0, yaw: -3...3),
        ])
    }

    func testAddingAPassAtANewDistanceKeepsBothSortedFurthestFirst() {
        let model = LookModel(passes: [close]).adding(far)
        XCTAssertEqual(model.passes.map(\.faceHeight), [0.25, 0.377])
    }

    func testAddingAPassAtAboutTheSameDistanceReplacesTheOldOne() {
        var again = close
        again.faceHeight = 0.40
        let model = LookModel(passes: [far, close]).adding(again)
        XCTAssertEqual(model.passes.map(\.faceHeight), [0.25, 0.40])
    }

    func testTargetsBetweenTwoPassesAreInterpolatedByFaceHeight() throws {
        let model = LookModel(passes: [far, close])
        let halfway = (0.25 + 0.377) / 2
        let targets = model.targets(atFaceHeight: halfway)
        let topTarget = try XCTUnwrap(targets.first { $0.displayUUID == top })
        XCTAssertEqual(topTarget.pitch.lowerBound, (5.0 + -17.5) / 2, accuracy: 1e-9)
        XCTAssertEqual(topTarget.pitch.upperBound, (6.5 + 4.0) / 2, accuracy: 1e-9)
    }

    func testTargetsAtAPassesOwnDistanceAreThatPass() {
        let model = LookModel(passes: [far, close])
        XCTAssertEqual(model.targets(atFaceHeight: 0.25), far.targets)
        XCTAssertEqual(model.targets(atFaceHeight: 0.377), close.targets)
    }

    func testBeyondTheFurthestPassTheTangentRuleScalesIt() throws {
        let model = LookModel(passes: [far, close])
        let target = try XCTUnwrap(model.targets(atFaceHeight: 0.2).first { $0.displayUUID == bottom })
        XCTAssertEqual(target.pitch, LookModel.scaled(7.5...9.0, by: 0.2 / 0.25))
    }

    func testLeaningBackWithOnlyTheClosePassReadsEverythingAsBottom() {
        // The failure that motivated passes: scaled from the close pass, the bottom screen covers
        // pitch 0.5 to 12 degrees back there, so looking at the top screen (5.5) still reads bottom.
        var picker = LookPicker(model: LookModel(passes: [close]))
        _ = picker.update(FaceFixtures.face(pitchDegrees: 8.5, faceHeight: 0.25), at: 0, locked: false)
        for frame in 1...15 {
            _ = picker.update(FaceFixtures.face(pitchDegrees: 5.5, faceHeight: 0.25), at: Double(frame) / fps, locked: false)
        }
        XCTAssertEqual(picker.current, bottom)
    }

    func testWithAFarPassLeaningBackTellsTheScreensApart() {
        var picker = LookPicker(model: LookModel(passes: [far, close]))
        _ = picker.update(FaceFixtures.face(pitchDegrees: 8.5, faceHeight: 0.25), at: 0, locked: false)
        XCTAssertEqual(picker.current, bottom)
        for frame in 1...15 {
            _ = picker.update(FaceFixtures.face(pitchDegrees: 5.5, faceHeight: 0.25), at: Double(frame) / fps, locked: false)
        }
        XCTAssertEqual(picker.current, top)
    }
}
