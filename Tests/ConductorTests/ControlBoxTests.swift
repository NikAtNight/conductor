import XCTest
@testable import Conductor

final class ControlBoxTests: XCTestCase {
    let laptop = CGRect(x: 0, y: 0, width: 1440, height: 900)          // 16:10
    let left = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let right = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
    let upper = CGRect(x: -320, y: -1440, width: 2560, height: 1440)   // stacked above `left`

    private func input(target: CGRect, cameraX: CGFloat, cameraDisplay: CGRect,
                       matchShape: Bool = true, width: CGFloat = 0.6, height: CGFloat = 0.5,
                       offsetY: CGFloat = 0.05) -> ControlBox.Input {
        ControlBox.Input(width: width, height: height, offsetY: offsetY, matchShape: matchShape,
                         target: target, cameraX: cameraX, cameraDisplay: cameraDisplay)
    }

    func testSingleDisplayWithoutShapeMatchingKeepsTheOldCenteredBox() {
        let box = ControlBox.layout(input(target: laptop, cameraX: laptop.midX, cameraDisplay: laptop, matchShape: false))
        XCTAssertEqual(box.minX, 0.2, accuracy: 1e-9)
        XCTAssertEqual(box.minY, 0.2, accuracy: 1e-9)   // (1 - 0.5) / 2 - 0.05
        XCTAssertEqual(box.height, 0.5, accuracy: 1e-9)
    }

    func testShapeMatchingGivesEqualPixelsPerCentimeterOnBothAxes() {
        let box = ControlBox.layout(input(target: laptop, cameraX: laptop.midX, cameraDisplay: laptop))
        // Box in camera pixels must have the screen's aspect ratio.
        let boxAspect = (box.width * 640) / (box.height * 480)
        XCTAssertEqual(boxAspect, laptop.width / laptop.height, accuracy: 1e-6)
    }

    func testSideBySideWithCameraOnLeftScreenShiftsBoxRight() {
        let union = left.union(right)
        let box = ControlBox.layout(input(target: union, cameraX: left.midX, cameraDisplay: left))
        // The camera's spot (a quarter of the way across the layout) sits at frame center.
        XCTAssertEqual(box.minX + 0.25 * box.width, 0.5, accuracy: 1e-9)
        XCTAssertGreaterThan(box.midX, 0.5)
    }

    func testCameraBetweenTwoScreensCentersTheBox() {
        let union = left.union(right)
        let box = ControlBox.layout(input(target: union, cameraX: union.midX, cameraDisplay: left))
        XCTAssertEqual(box.midX, 0.5, accuracy: 1e-9)
    }

    func testStackedLayoutGetsATallBoxThatFitsTheFrame() {
        let union = left.union(upper)
        let box = ControlBox.layout(input(target: union, cameraX: left.midX, cameraDisplay: left))
        XCTAssertGreaterThan(box.height, box.width, "a tall layout needs a tall box")
        XCTAssertGreaterThanOrEqual(box.minY, ControlBox.topMargin - 1e-9)
        XCTAssertLessThanOrEqual(box.maxY, 1 - ControlBox.bottomMargin + 1e-9)
        let boxAspect = (box.width * 640) / (box.height * 480)
        XCTAssertEqual(boxAspect, union.width / union.height, accuracy: 1e-6, "shrinking keeps the shape")
    }

    func testStackedWithCameraOnLowerScreenPutsUpperScreenAbove() {
        let union = left.union(upper)
        let box = ControlBox.layout(input(target: union, cameraX: left.midX, cameraDisplay: left))
        // The lower screen's center should be lower in the frame than the upper screen's center.
        let lowerCenterY = box.minY + (left.midY - union.minY) / union.height * box.height
        let upperCenterY = box.minY + (upper.midY - union.minY) / union.height * box.height
        XCTAssertGreaterThan(lowerCenterY, upperCenterY)
    }

    func testFarAwayCameraClampsTheBoxInsideTheFrame() {
        // Main-display mode, camera mounted on a screen far to the left.
        let box = ControlBox.layout(input(target: right, cameraX: -3000, cameraDisplay: left))
        XCTAssertGreaterThanOrEqual(box.minX, ControlBox.sideMargin - 1e-9)
        XCTAssertLessThanOrEqual(box.maxX, 1 - ControlBox.sideMargin + 1e-9)
        XCTAssertEqual(box.maxX, 1 - ControlBox.sideMargin, accuracy: 1e-9, "pushed toward the far side")
    }
}

final class DisplayLayoutTests: XCTestCase {
    let main = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let small = CGRect(x: 0, y: -900, width: 1440, height: 900)   // narrower, stacked above

    func testPointOnAScreenIsUnchanged() {
        XCTAssertEqual(DisplayLayout.snap(CGPoint(x: 100, y: 100), to: [main, small]), CGPoint(x: 100, y: 100))
    }

    func testPointInTheEmptyCornerSnapsToTheNearestScreen() {
        // Right of `small` and well above `main`: no display there, and `small` is nearer.
        XCTAssertEqual(DisplayLayout.snap(CGPoint(x: 1500, y: -800), to: [main, small]), CGPoint(x: 1439, y: -800))
        // Just above `main`'s right side: `main` is nearer.
        XCTAssertEqual(DisplayLayout.snap(CGPoint(x: 1800, y: -100), to: [main, small]), CGPoint(x: 1800, y: 0))
    }

    func testFarEdgeIsPulledOntoTheLastPixel() {
        XCTAssertEqual(DisplayLayout.snap(CGPoint(x: 1920, y: 1080), to: [main]), CGPoint(x: 1919, y: 1079))
    }

    private func display(_ uuid: String, _ bounds: CGRect, builtin: Bool = false, main: Bool = false) -> DisplayInfo {
        DisplayInfo(uuid: uuid, name: uuid, bounds: bounds, isBuiltin: builtin, isMain: main)
    }

    func testAutomaticPlacementUsesTheBuiltInDisplayForTheBuiltInCamera() {
        let displays = [display("ext", main, main: true), display("lap", CGRect(x: -1440, y: 200, width: 1440, height: 900), builtin: true)]
        let resolved = CameraPlacement.resolve(nil, displays: displays, builtInCamera: true)
        XCTAssertEqual(resolved?.display.uuid, "lap")
        XCTAssertEqual(resolved?.x, -720)
        XCTAssertEqual(CameraPlacement.resolve(nil, displays: displays, builtInCamera: false)?.display.uuid, "ext")
    }

    func testSavedPlacementWinsAndFallsBackWhenTheDisplayIsGone() {
        let displays = [display("a", main, main: true), display("b", CGRect(x: 1920, y: 0, width: 1000, height: 800))]
        let saved = CameraPlacement(displayUUID: "b", x: 0.25)
        XCTAssertEqual(CameraPlacement.resolve(saved, displays: displays, builtInCamera: false)?.x, 2170)
        let gone = CameraPlacement(displayUUID: "unplugged", x: 0.25)
        XCTAssertEqual(CameraPlacement.resolve(gone, displays: displays, builtInCamera: false)?.display.uuid, "a")
    }
}
