// WP0 placeholder so the target exists; WP5 owns Tests/HMBBenchTests/**.
import HMBBench
import HMBModel
import Testing

@Suite struct BenchScaffoldTests {
    @Test func moduleLinks() {
        #expect(DeliveryPreset.builtIns.count == 4)
    }
}
