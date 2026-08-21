import Cocoa
import FlutterMacOS
import XCTest
@testable import MeowSTT

private final class CursorHostView: NSView {
  private(set) var recordedCursor: NSCursor?

  @objc func didUpdateMouseCursor(_ cursor: NSCursor) {
    recordedCursor = cursor
  }
}

class RunnerTests: XCTestCase {

  override func tearDown() {
    NSCursor.arrow.set()
    super.tearDown()
  }

  func testCursorGenerationRejectsLateCrossTypeClear() {
    let host = CursorHostView()
    let controller = TranscriptStructureCursorController(hostView: host)

    controller.activate(kind: .split, session: 1)
    XCTAssertTrue(NSCursor.current === controller.cursor(for: .split))
    XCTAssertTrue(host.recordedCursor === controller.cursor(for: .split))
    controller.activate(kind: .merge, session: 2)
    controller.deactivate(session: 1)

    XCTAssertEqual(controller.activeKind, .merge)
    XCTAssertTrue(NSCursor.current === controller.cursor(for: .merge))
  }

  func testCursorClearPreservesNewAppKitCursorWrite() {
    let host = CursorHostView()
    let controller = TranscriptStructureCursorController(hostView: host)
    controller.activate(kind: .split, session: 1)
    NSCursor.iBeam.set()

    controller.deactivate(session: 1)

    XCTAssertNil(controller.activeKind)
    XCTAssertTrue(NSCursor.current === NSCursor.iBeam)
  }

  func testClearAllPreservesAndRecordsActualCrossTypeCursor() {
    let host = CursorHostView()
    let controller = TranscriptStructureCursorController(hostView: host)
    controller.activate(kind: .split, session: 1)
    NSCursor.iBeam.set()

    controller.deactivateAll()

    XCTAssertTrue(NSCursor.current === NSCursor.iBeam)
    XCTAssertTrue(host.recordedCursor === NSCursor.iBeam)
  }

}
