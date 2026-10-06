import XCTest
@testable import Conductor

private func spread(_ mean: Double, _ sd: Double) -> LookModel.Spread { LookModel.Spread(mean: mean, sd: sd) }

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

    func testTwoStackedDisplaysGiveMeansInsideTheSampledPitchRanges() throws {
        let all = samples(top, pitch: 3...7) + samples(bottom, pitch: 10...14)
        let pass = try LookCalibration.pass(from: all, displays: [top, bottom]).get()
        XCTAssertEqual(pass.targets.map(\.displayUUID), [top, bottom])
        XCTAssertTrue((3.0...7.0).contains(pass.targets[0].pitch.mean))
        XCTAssertTrue((10.0...14.0).contains(pass.targets[1].pitch.mean))
        // Evenly spaced and symmetric, so the trimmed mean is the middle of the range.
        XCTAssertEqual(pass.targets[0].pitch.mean, 5, accuracy: 1e-9)
        XCTAssertEqual(pass.targets[1].pitch.mean, 12, accuracy: 1e-9)
        XCTAssertEqual(pass.targets[0].yaw.mean, 0, accuracy: 1e-9)
    }

    func testSpreadIsTheStandardDeviationOfTheSamplesLeftAfterTrimming() throws {
        let all = samples(top, pitch: 3...7) + samples(bottom, pitch: 10...14)
        let yaw = try LookCalibration.pass(from: all, displays: [top, bottom]).get().targets[0].yaw
        // 20 evenly spaced yaw values, 5% (one) dropped each side: 18 values 20/19 degrees apart.
        let spacing = 20.0 / 19.0, n = 18.0
        XCTAssertEqual(yaw.sd, spacing * ((n * n - 1) / 12).squareRoot(), accuracy: 1e-9)
    }

    func testASingleOutlierAtPitchFortyBarelyMovesTheMean() throws {
        let outlier = LookCalibration.Sample(displayUUID: top, pitch: 40, yaw: 0, faceHeight: 0.4)
        let all = samples(top, pitch: 3...7) + [outlier] + samples(bottom, pitch: 10...14)
        let pitch = try LookCalibration.pass(from: all, displays: [top, bottom]).get().targets[0].pitch
        // The outlier and the lowest sample are both trimmed, leaving a mean of about 5.1.
        XCTAssertEqual(pitch.mean, 5, accuracy: 0.2)
        XCTAssertLessThan(pitch.sd, 2)
    }

    func testThePassFaceHeightIsTheMedianOfAllSamples() throws {
        // 41 samples with heights 0.30...0.50, so the middle one is 0.40.
        let all = samples(top, pitch: 3...7, count: 20, height: { 0.30 + 0.01 * Double($0) })
            + samples(bottom, pitch: 10...14, count: 21, height: { 0.30 + 0.01 * Double($0) })
        let pass = try LookCalibration.pass(from: all, displays: [top, bottom]).get()
        XCTAssertEqual(pass.faceHeight, 0.40, accuracy: 1e-9)
    }

    func testTooFewSamplesForOneDisplayNamesThatDisplay() {
        let few = LookCalibration.minimumSamplesPerDisplay - 1
        let all = samples(top, pitch: 3...7) + samples(bottom, pitch: 10...14, count: few)
        XCTAssertEqual(LookCalibration.pass(from: all, displays: [top, bottom]),
                       .failure(.tooFewSamples(displayUUID: bottom)))
    }

    func testExactlyTheMinimumSampleCountIsEnough() throws {
        let enough = LookCalibration.minimumSamplesPerDisplay
        let all = samples(top, pitch: 3...7, count: enough) + samples(bottom, pitch: 10...14, count: enough)
        _ = try LookCalibration.pass(from: all, displays: [top, bottom]).get()
    }

    func testADisplayWithNoSamplesAtAllIsTooFew() {
        XCTAssertEqual(LookCalibration.pass(from: samples(top, pitch: 3...7), displays: [top, bottom]),
                       .failure(.tooFewSamples(displayUUID: bottom)))
    }

    func testDisplaysSampledOverTheSameAnglesAreIndistinct() {
        let all = samples(top, pitch: 3...7) + samples(bottom, pitch: 3...7)
        XCTAssertEqual(LookCalibration.pass(from: all, displays: [top, bottom]), .failure(.indistinct(top, bottom)))
    }

    func testAWellSeparatedPassIsClear() throws {
        let all = samples(top, pitch: 3...7) + samples(bottom, pitch: 10...14)
        let pass = try LookCalibration.pass(from: all, displays: [top, bottom]).get()
        XCTAssertEqual(LookCalibration.quality(of: pass), .clear)
    }

    // MARK: quality, with the numbers measured at the desk

    /// Close pass, face height 0.377. By hand: pooled pitch sd = sqrt((6.5^2 + 5.2^2) / 2) = 5.886,
    /// pooled yaw sd = sqrt((14^2 + 9^2) / 2) = 11.769. Pitch gap 16 / 5.886 = 2.718, yaw gap
    /// 7.8 / 11.769 = 0.663, separation sqrt(2.718^2 + 0.663^2) = 2.798.
    private var closePass: LookModel.Pass {
        LookModel.Pass(faceHeight: 0.377, targets: [
            LookModel.Target(displayUUID: top, pitch: spread(-6.7, 6.5), yaw: spread(-3, 14)),
            LookModel.Target(displayUUID: bottom, pitch: spread(9.3, 5.2), yaw: spread(4.8, 9)),
        ])
    }

    /// Far pass, face height 0.30. Pooled pitch sd = sqrt((3.7^2 + 1.7^2) / 2) = 2.879, pooled yaw
    /// sd = sqrt((7.8^2 + 3.6^2) / 2) = 6.075. Pitch gap 6.2 / 2.879 = 2.153, yaw gap 7.1 / 6.075 =
    /// 1.169, separation sqrt(2.153^2 + 1.169^2) = 2.450.
    private var farPass: LookModel.Pass {
        LookModel.Pass(faceHeight: 0.30, targets: [
            LookModel.Target(displayUUID: top, pitch: spread(-2.8, 3.7), yaw: spread(-3.2, 7.8)),
            LookModel.Target(displayUUID: bottom, pitch: spread(3.4, 1.7), yaw: spread(3.9, 3.6)),
        ])
    }

    func testTheClosePassIsClear() {
        let separation = LookModel.weakestSeparation(closePass)
        XCTAssertEqual(separation, 2.798, accuracy: 0.005)
        XCTAssertGreaterThan(separation, LookCalibration.minimumSeparation)
        XCTAssertEqual(LookCalibration.quality(of: closePass), .clear)
    }

    func testTheFarPassIsSavedButWeak() {
        let separation = LookModel.weakestSeparation(farPass)
        XCTAssertEqual(separation, 2.450, accuracy: 0.005)
        XCTAssertGreaterThanOrEqual(separation, LookCalibration.minimumSeparation)
        XCTAssertLessThan(separation, LookCalibration.clearSeparation)
        XCTAssertEqual(LookCalibration.quality(of: farPass), .weak)
    }

    func testPooledSpreadIsTheRootMeanSquareAndNeverBelowTheMinimum() {
        let pooled = LookModel.pooledSpread(closePass.targets)
        XCTAssertEqual(pooled.pitch, 5.886, accuracy: 0.001)
        XCTAssertEqual(pooled.yaw, 11.769, accuracy: 0.001)
        let still = LookModel.pooledSpread([LookModel.Target(displayUUID: top, pitch: spread(0, 0.1), yaw: spread(0, 0.2))])
        XCTAssertEqual(still.pitch, LookModel.minimumSpread)
        XCTAssertEqual(still.yaw, LookModel.minimumSpread)
    }

    func testASingleDisplayHasNoWeakestSeparation() {
        let pass = LookModel.Pass(faceHeight: 0.4, targets: [closePass.targets[0]])
        XCTAssertEqual(LookModel.weakestSeparation(pass), .infinity)
    }

    // MARK: samples

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
    let side = "side"

    /// Frames arrive at 30 fps; frame `n` is at n / 30 seconds.
    private let fps = 30.0
    private func time(_ frame: Int) -> TimeInterval { Double(frame) / fps }
    /// Dwell is 0.25 s, which is 7.5 frames. A candidate first seen at frame 1 has waited long
    /// enough at frame 1 + dwellFrames (8 frames later), and not yet at frame dwellFrames.
    private var dwellFrames: Int { Int((LookPicker.dwell * fps).rounded(.up)) }

    /// Top averages pitch 5 and bottom pitch 12, both spread 2 degrees in pitch and 3 in yaw, so
    /// the midpoint is pitch 8.5 and a pooled spread is 2 degrees of pitch.
    private func target(_ uuid: String, pitch: Double, yaw: Double = 0) -> LookModel.Target {
        LookModel.Target(displayUUID: uuid, pitch: spread(pitch, 2), yaw: spread(yaw, 3))
    }

    private func model(topPitch: Double = 5, bottomPitch: Double = 12, faceHeight: Double = 0.4) -> LookModel {
        LookModel(targets: [target(top, pitch: topPitch), target(bottom, pitch: bottomPitch)], faceHeight: faceHeight)
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

    func testTheFirstFaceBeyondEveryAveragePicksTheNearest() {
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
        XCTAssertEqual(feed(&picker, FaceFixtures.face(pitchDegrees: 5), frames: 1...dwellFrames), bottom)
    }

    func testLookingAtTheOtherDisplayForDwellSwitchesThePick() {
        var picker = pickerOnBottom()
        XCTAssertEqual(feed(&picker, FaceFixtures.face(pitchDegrees: 5), frames: 1...(1 + dwellFrames)), top)
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
        // One second of looking at top while locked, well past dwell.
        XCTAssertEqual(feed(&picker, FaceFixtures.face(pitchDegrees: 5), frames: 1...30, locked: true), bottom)
    }

    func testTheSwitchHappensOnceTheLockEndsIfTheHeadIsStillThere() {
        var picker = pickerOnBottom()
        let look = FaceFixtures.face(pitchDegrees: 5)
        feed(&picker, look, frames: 1...30, locked: true)
        XCTAssertEqual(picker.update(look, at: time(31), locked: false), top)
    }

    func testAFaceAtTheMidpointBetweenTwoAveragesDoesNotSwitchEitherWay() {
        // Midpoint of 5 and 12 is 8.5. The other display has to be 0.5 pooled spreads (1 degree of
        // pitch here) closer, so 8.8 and 8.2 are inside the dead band.
        var onTop = LookPicker(model: model())
        _ = onTop.update(FaceFixtures.face(pitchDegrees: 5), at: 0, locked: false)
        XCTAssertEqual(feed(&onTop, FaceFixtures.face(pitchDegrees: 8.5), frames: 1...30), top)
        XCTAssertEqual(feed(&onTop, FaceFixtures.face(pitchDegrees: 8.8), frames: 31...60), top)

        var onBottom = pickerOnBottom()
        XCTAssertEqual(feed(&onBottom, FaceFixtures.face(pitchDegrees: 8.5), frames: 1...30), bottom)
        XCTAssertEqual(feed(&onBottom, FaceFixtures.face(pitchDegrees: 8.2), frames: 31...60), bottom)
    }

    func testLeavingTheDeadBandTowardTheOtherDisplaySwitchesAfterDwell() {
        var picker = LookPicker(model: model())
        _ = picker.update(FaceFixtures.face(pitchDegrees: 5), at: 0, locked: false)
        XCTAssertEqual(feed(&picker, FaceFixtures.face(pitchDegrees: 9.5), frames: 1...(1 + dwellFrames)), bottom)
    }

    func testNoFaceReturnsTheCurrentPick() {
        var picker = pickerOnBottom()
        XCTAssertEqual(picker.update(nil, at: time(1), locked: false), bottom)
    }

    func testNoFaceBeforeAnyPickReturnsNil() {
        var picker = LookPicker(model: model())
        XCTAssertNil(picker.update(nil, at: 0, locked: false))
    }

    func testLosingTheFaceResetsTheDwellSoTheNextGlanceRestartsIt() {
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

    // MARK: distance scaling

    func testACloserFaceScalesTheAveragesUpSoAHigherAngleStillCountsAsBottom() {
        // Calibrated at face height 0.3. At 0.45 (1.5x closer) the averages become about 7.5 for
        // top and 17.7 for bottom, so pitch 16 is clearly bottom.
        var picker = LookPicker(model: model(faceHeight: 0.3))
        XCTAssertEqual(picker.update(FaceFixtures.face(pitchDegrees: 5, faceHeight: 0.3), at: 0, locked: false), top)
        let closeAndLow = FaceFixtures.face(pitchDegrees: 16, faceHeight: 0.45)
        XCTAssertEqual(feed(&picker, closeAndLow, frames: 1...(1 + dwellFrames)), bottom)
    }

    func testACloserFaceAtAnAngleNearTheRawBottomAverageReadsAsTop() {
        // Same calibration. Pitch 11 is near the raw bottom average (12), but 1.5x closer the bottom
        // average is about 17.7 and the top one about 7.5, so top is nearer.
        var picker = pickerOnBottom(model(faceHeight: 0.3), faceHeight: 0.3)
        let close = FaceFixtures.face(pitchDegrees: 11, faceHeight: 0.45)
        XCTAssertEqual(feed(&picker, close, frames: 1...(1 + dwellFrames)), top)
    }

    // MARK: manual override

    func testAnOverrideSetsThePickAtOnce() {
        var picker = pickerOnBottom()
        picker.override(to: top)
        XCTAssertEqual(picker.current, top)
    }

    func testAnOverrideSticksWhileTheHeadKeepsPointingAtTheOldDisplay() {
        var picker = pickerOnBottom()
        picker.override(to: top)
        // Two seconds with the head still on bottom, far past dwell.
        XCTAssertEqual(feed(&picker, FaceFixtures.face(pitchDegrees: 12), frames: 1...60), top)
    }

    func testAnOverrideReleasesOnceTheHeadPointsAtTheOverriddenDisplayThenSwitchesNormally() {
        var picker = pickerOnBottom()
        picker.override(to: top)
        feed(&picker, FaceFixtures.face(pitchDegrees: 12), frames: 1...10)
        // The head turns to top, which releases the hold. The pick stays top.
        XCTAssertEqual(feed(&picker, FaceFixtures.face(pitchDegrees: 5), frames: 11...20), top)
        // Looking back at bottom now switches after dwell, with no hold in the way.
        let back = FaceFixtures.face(pitchDegrees: 12)
        XCTAssertEqual(feed(&picker, back, frames: 21...(20 + dwellFrames)), top)
        XCTAssertEqual(picker.update(back, at: time(21 + dwellFrames), locked: false), bottom)
    }

    func testAnOverrideReleasesWhenTheHeadPointsAtADifferentThirdDisplay() {
        var picker = LookPicker(model: LookModel(targets: [target(top, pitch: 5), target(bottom, pitch: 12),
                                                           target(side, pitch: 5, yaw: 30)], faceHeight: 0.4))
        _ = picker.update(FaceFixtures.face(pitchDegrees: 12), at: 0, locked: false)
        XCTAssertEqual(picker.current, bottom)
        picker.override(to: top)
        XCTAssertEqual(feed(&picker, FaceFixtures.face(pitchDegrees: 12), frames: 1...10), top)
        let aside = FaceFixtures.face(pitchDegrees: 5, yawDegrees: 30)
        XCTAssertEqual(feed(&picker, aside, frames: 11...(10 + dwellFrames)), top)
        XCTAssertEqual(picker.update(aside, at: time(11 + dwellFrames), locked: false), side)
    }

    func testAnOverrideWaitsForTheNextFaceToLearnWhereTheHeadPoints() {
        var picker = pickerOnBottom()
        picker.override(to: top)
        XCTAssertEqual(picker.update(nil, at: time(1), locked: false), top)
        XCTAssertEqual(feed(&picker, FaceFixtures.face(pitchDegrees: 12), frames: 2...60), top)
    }

    func testAGlanceDuringAHoldDoesNotReleaseIt() {
        // Weak calibration: the head jitters across the midpoint between screens. One frame on the
        // top side used to release the hold, after which the next dwell on bottom undid the switch.
        var picker = pickerOnBottom()
        picker.override(to: top)
        feed(&picker, FaceFixtures.face(pitchDegrees: 12), frames: 1...10)
        XCTAssertEqual(picker.update(FaceFixtures.face(pitchDegrees: 5), at: time(11), locked: false), top)
        XCTAssertEqual(feed(&picker, FaceFixtures.face(pitchDegrees: 12), frames: 12...(12 + 4 * dwellFrames)), top)
    }

    func testHoveringAtTheMidpointDuringAHoldNeverReleasesIt() {
        var picker = pickerOnBottom()
        picker.override(to: top)
        feed(&picker, FaceFixtures.face(pitchDegrees: 12), frames: 1...10)
        for frame in 11...(11 + 8 * dwellFrames) {
            // Alternating a hair either side of the midpoint (8.5), every frame.
            let pitch = frame.isMultiple(of: 2) ? 8.4 : 8.6
            XCTAssertEqual(picker.update(FaceFixtures.face(pitchDegrees: pitch), at: time(frame), locked: false), top)
        }
        XCTAssertEqual(feed(&picker, FaceFixtures.face(pitchDegrees: 12), frames: 200...(200 + 4 * dwellFrames)), top,
                       "the hold is still on: back on bottom doesn't switch")
    }
}

/// Passes per sitting distance, with numbers from Nikhil's desk: up close the head sweeps far
/// more per screen than when leaning back, so the two passes look nothing alike.
final class LookModelPassesTests: XCTestCase {
    let top = "top"
    let bottom = "bottom"
    let fps = 30.0

    /// Measured at face height 0.377 (close) and 0.30 (far).
    var close: LookModel.Pass {
        LookModel.Pass(faceHeight: 0.377, targets: [
            LookModel.Target(displayUUID: top, pitch: spread(-6.7, 6.5), yaw: spread(-3, 14)),
            LookModel.Target(displayUUID: bottom, pitch: spread(9.3, 5.2), yaw: spread(4.8, 9)),
        ])
    }
    var far: LookModel.Pass {
        LookModel.Pass(faceHeight: 0.30, targets: [
            LookModel.Target(displayUUID: top, pitch: spread(-2.8, 3.7), yaw: spread(-3.2, 7.8)),
            LookModel.Target(displayUUID: bottom, pitch: spread(3.4, 1.7), yaw: spread(3.9, 3.6)),
        ])
    }

    private func target(_ uuid: String, in targets: [LookModel.Target]) throws -> LookModel.Target {
        try XCTUnwrap(targets.first { $0.displayUUID == uuid })
    }

    func testAddingAPassAtANewDistanceKeepsBothSortedFurthestFirst() {
        XCTAssertEqual(LookModel(passes: [close]).adding(far).passes.map(\.faceHeight), [0.30, 0.377])
        XCTAssertEqual(LookModel(passes: [far]).adding(close).passes.map(\.faceHeight), [0.30, 0.377])
    }

    func testAddingAPassWithinTheSamePlaceToleranceReplacesTheOldOne() {
        var again = close
        again.faceHeight = 0.40
        again.targets[0].pitch = spread(-7, 6)
        let model = LookModel(passes: [far, close]).adding(again)
        XCTAssertEqual(model.passes.map(\.faceHeight), [0.30, 0.40])
        XCTAssertEqual(model.passes[1], again)
    }

    func testTargetsHalfwayBetweenTwoPassesMixMeanAndSpreadLinearly() throws {
        let model = LookModel(passes: [far, close])
        let halfway = try target(top, in: model.targets(atFaceHeight: (0.30 + 0.377) / 2))
        XCTAssertEqual(halfway.pitch.mean, (-2.8 + -6.7) / 2, accuracy: 1e-9)
        XCTAssertEqual(halfway.pitch.sd, (3.7 + 6.5) / 2, accuracy: 1e-9)
        XCTAssertEqual(halfway.yaw.mean, (-3.2 + -3.0) / 2, accuracy: 1e-9)
        XCTAssertEqual(halfway.yaw.sd, (7.8 + 14.0) / 2, accuracy: 1e-9)
    }

    func testTargetsAtAPassesOwnFaceHeightAreExactlyThatPass() {
        let model = LookModel(passes: [far, close])
        XCTAssertEqual(model.targets(atFaceHeight: 0.30), far.targets)
        XCTAssertEqual(model.targets(atFaceHeight: 0.377), close.targets)
    }

    func testBeyondTheFurthestPassMeansAreScaledAndSpreadsScaleByTheRatio() throws {
        let model = LookModel(passes: [far, close])
        let ratio = 0.2 / 0.30
        let bottomTarget = try target(bottom, in: model.targets(atFaceHeight: 0.2))
        XCTAssertEqual(bottomTarget.pitch.mean, LookModel.scaled(3.4, by: ratio), accuracy: 1e-9)
        XCTAssertEqual(bottomTarget.pitch.sd, 1.7 * ratio, accuracy: 1e-9)
        XCTAssertEqual(bottomTarget.yaw.mean, LookModel.scaled(3.9, by: ratio), accuracy: 1e-9)
        XCTAssertEqual(bottomTarget.yaw.sd, 3.6 * ratio, accuracy: 1e-9)
    }

    func testBeyondTheNearestPassScalesTheNearestPass() throws {
        let model = LookModel(passes: [far, close])
        let ratio = 0.5 / 0.377
        let topTarget = try target(top, in: model.targets(atFaceHeight: 0.5))
        XCTAssertEqual(topTarget.pitch.mean, LookModel.scaled(-6.7, by: ratio), accuracy: 1e-9)
        XCTAssertEqual(topTarget.pitch.sd, 6.5 * ratio, accuracy: 1e-9)
    }

    func testAnEmptyModelHasNoTargets() {
        XCTAssertEqual(LookModel(passes: []).targets(atFaceHeight: 0.3), [])
    }

    func testScaledByRatioOneLeavesAnAngleUnchanged() {
        XCTAssertEqual(LookModel.scaled(10, by: 1), 10, accuracy: 1e-9)
    }

    func testScaledScalesTheTangentOfTheAngleByTheRatio() {
        let expected = atan(tan(10 * Double.pi / 180) * 1.5) * 180 / .pi
        XCTAssertEqual(LookModel.scaled(10, by: 1.5), expected, accuracy: 1e-9)
        XCTAssertGreaterThan(LookModel.scaled(10, by: 1.5), 10)
    }

    func testScaledIsSymmetricAroundZero() {
        XCTAssertEqual(LookModel.scaled(-10, by: 1.5), -LookModel.scaled(10, by: 1.5), accuracy: 1e-9)
        XCTAssertLessThan(LookModel.scaled(-10, by: 1.5), -10)
        XCTAssertEqual(LookModel.scaled(0, by: 1.5), 0, accuracy: 1e-9)
    }

    // MARK: the case ranges got wrong

    func testLeaningBackWithOnlyTheFarPassStillSwitchesFromBottomToTopAtPitchMinusOne() {
        // Far pass alone. Pitch 5 is nearest bottom (0.85 spreads against 2.76 from top). Pitch -1
        // is nearest top (0.82 against 1.66), a gap of 0.84 spreads, over the 0.5 margin. Under the
        // old range model the two screens' ranges overlapped here and the pick stuck on bottom.
        var picker = LookPicker(model: LookModel(passes: [far]))
        XCTAssertEqual(picker.update(FaceFixtures.face(pitchDegrees: 5, faceHeight: 0.30), at: 0, locked: false), bottom)
        let dwellFrames = Int((LookPicker.dwell * fps).rounded(.up))
        let look = FaceFixtures.face(pitchDegrees: -1, faceHeight: 0.30)
        var pick: String?
        for frame in 1...(1 + dwellFrames) { pick = picker.update(look, at: Double(frame) / fps, locked: false) }
        XCTAssertEqual(pick, top)
    }
}
