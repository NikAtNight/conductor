import XCTest
@testable import Conductor

@MainActor
final class LookModelStorageTests: XCTestCase {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "LookModelStorageTests.\(UUID())")!
    }

    private var twoPassModel: LookModel {
        func target(_ pitch: LookModel.Spread, _ yaw: LookModel.Spread) -> LookModel.Target {
            LookModel.Target(displayUUID: "a", pitch: pitch, yaw: yaw)
        }
        return LookModel(passes: [
            LookModel.Pass(faceHeight: 0.30, targets: [target(.init(mean: -2.8, sd: 3.7), .init(mean: -3.2, sd: 7.8))]),
            LookModel.Pass(faceHeight: 0.377, targets: [target(.init(mean: -6.7, sd: 6.5), .init(mean: -3, sd: 14))]),
        ])
    }

    func testATwoPassModelRoundTripsThroughPreferences() {
        let suite = defaults()
        let model = twoPassModel
        Preferences(defaults: suite).settings.lookModel = model
        XCTAssertEqual(Preferences(defaults: suite).settings.lookModel, model)
    }

    func testAModelSavedAsAngleRangesLoadsAsNotCalibrated() {
        let old = """
        {"passes":[{"faceHeight":0.3,"targets":[{"displayUUID":"a","pitch":[-8.9,3.3],"yaw":[-16,9.6]}]}]}
        """
        let suite = defaults()
        suite.set(Data(old.utf8), forKey: "lookModel")
        XCTAssertNil(Preferences(defaults: suite).settings.lookModel)
    }

    func testAFlatSinglePassFromTheFirstBuildsLoadsAsNotCalibrated() {
        let flat = """
        {"targets":[{"displayUUID":"a","pitch":[-17.5,4.0],"yaw":[-26.6,20.6]}],"faceHeight":0.377}
        """
        let suite = defaults()
        suite.set(Data(flat.utf8), forKey: "lookModel")
        XCTAssertNil(Preferences(defaults: suite).settings.lookModel)
    }

    func testLoadingPreferencesDoesNotOverwriteTheSavedModel() {
        let suite = defaults()
        let model = twoPassModel
        Preferences(defaults: suite).settings.lookModel = model
        // Opening and dropping Preferences again must leave the stored model alone, however many
        // times, since init saves what it loaded.
        _ = Preferences(defaults: suite)
        _ = Preferences(defaults: suite)
        XCTAssertEqual(Preferences(defaults: suite).settings.lookModel, model)
    }
}
