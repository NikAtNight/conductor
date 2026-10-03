import XCTest
@testable import Conductor

@MainActor
final class LookModelStorageTests: XCTestCase {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "LookModelStorageTests.\(UUID())")!
    }

    func testAModelRoundTripsThroughPreferences() {
        let suite = defaults()
        let model = LookModel(passes: [
            LookModel.Pass(faceHeight: 0.25, targets: [LookModel.Target(displayUUID: "a", pitch: 5...6.5, yaw: -3...3)]),
            LookModel.Pass(faceHeight: 0.38, targets: [LookModel.Target(displayUUID: "a", pitch: -17.5...4, yaw: -26...20)]),
        ])
        Preferences(defaults: suite).lookModel = model
        XCTAssertEqual(Preferences(defaults: suite).lookModel, model)
    }

    func testAFlatSinglePassFromTheFirstBuildsLoadsAsOnePass() throws {
        // What the first builds wrote: the pass's fields at the top level, no `passes` array.
        let flat = """
        {"targets":[{"displayUUID":"a","pitch":[-17.5,4.0],"yaw":[-26.6,20.6]}],"faceHeight":0.377}
        """
        let suite = defaults()
        suite.set(Data(flat.utf8), forKey: "lookModel")
        let model = try XCTUnwrap(Preferences(defaults: suite).lookModel)
        XCTAssertEqual(model.passes.count, 1)
        XCTAssertEqual(model.passes[0].faceHeight, 0.377)
        XCTAssertEqual(model.passes[0].targets.first?.displayUUID, "a")
    }
}
