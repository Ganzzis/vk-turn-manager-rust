// A new WireGuard session must authenticate before it can use the packet flow.
// Keep the installed routes during reassertion, including while traffic is dropped.
struct PacketFlowGate {
    private(set) var routesInstalled = false
    private(set) var active = false
    private(set) var generation: UInt64 = 0

    mutating func activate() {
        routesInstalled = true
        active = true
    }

    mutating func pause() {
        active = false
        generation &+= 1
    }

    func accepts(_ readGeneration: UInt64) -> Bool {
        active && readGeneration == generation
    }
}
