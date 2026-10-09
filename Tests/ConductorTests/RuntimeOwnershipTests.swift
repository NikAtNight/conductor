import XCTest
import Combine
@testable import Conductor

final class RuntimeOwnershipTests: XCTestCase {
    func testEverySamplingKindIsExclusiveAndStaleStopsCannotReleaseAnotherOwner() throws {
        for kind in [SamplingOwnership.Kind.reach, .look, .gestureCheck] {
            let owner = SamplingOwnership()
            var cancelled = 0
            let first = try XCTUnwrap(owner.claim(kind) { cancelled += 1 })
            for competing in [SamplingOwnership.Kind.reach, .look, .gestureCheck] {
                XCTAssertNil(owner.claim(competing) { XCTFail("rejected owner cannot be cancelled") })
            }
            owner.cancel()
            owner.cancel()
            XCTAssertEqual(cancelled, 1)
            XCTAssertFalse(owner.contains(first))
            let second = try XCTUnwrap(owner.claim(.look) { cancelled += 1 })
            XCTAssertFalse(owner.release(first))
            XCTAssertTrue(owner.contains(second))
            XCTAssertTrue(owner.release(second))
            owner.cancel()
            XCTAssertEqual(cancelled, 1, "normal release must not call cancellation")
        }
    }

    func testPreviewKeepsOnlyLatestValueAndRejectsFramesFromBeforeStopOrRestart() {
        let mailbox = LatestSnapshot<Int>()
        let first = mailbox.start()
        for frame in 0..<10_000 { mailbox.offer(frame, token: first) }
        XCTAssertEqual(mailbox.take(), 9_999)
        XCTAssertNil(mailbox.take())
        mailbox.offer(10_000, token: first)
        mailbox.stop()
        mailbox.offer(10_001, token: first)
        XCTAssertNil(mailbox.take())
        let second = mailbox.start()
        mailbox.offer(2, token: second)
        mailbox.offer(3, token: first)
        XCTAssertEqual(mailbox.take(), 2)
    }

    @MainActor
    func testUnchangedSnapshotDoesNotPublishScalarChanges() {
        let state = TrackingState()
        let snapshot = TrackingSnapshot(hands: [], face: nil, fps: 30, label: "Pointer",
                                        warning: nil, box: state.controlBox, targetName: nil)
        snapshot.publish(to: state)
        var changes = 0
        let token = state.objectWillChange.sink { changes += 1 }
        snapshot.publish(to: state)
        XCTAssertEqual(changes, 0)
        var changed = snapshot
        changed.fps = 29
        changed.publish(to: state)
        XCTAssertEqual(changes, 1)
        withExtendedLifetime(token) {}
    }
}
