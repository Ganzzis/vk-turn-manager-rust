import XCTest

final class PacketFlowGateTests: XCTestCase {
    func testReconnectKeepsRoutesAndDropsReadsFromThePreviousSession() {
        var gate = PacketFlowGate()
        XCTAssertFalse(gate.accepts(gate.generation))
        XCTAssertFalse(gate.routesInstalled)

        gate.activate()
        let pendingRead = gate.generation
        XCTAssertTrue(gate.accepts(pendingRead))

        gate.pause()
        XCTAssertTrue(gate.routesInstalled)
        XCTAssertFalse(gate.accepts(pendingRead))
        XCTAssertFalse(gate.accepts(gate.generation))

        gate.activate()
        XCTAssertFalse(gate.accepts(pendingRead))
        XCTAssertTrue(gate.accepts(gate.generation))

        let finalRead = gate.generation
        gate.pause()
        XCTAssertFalse(gate.active)
        XCTAssertFalse(gate.accepts(finalRead))
    }
}
