import Foundation

/// Deterministic generator (SplitMix64) for fixtures: the same seed gives the same wedding on every machine.
public struct FixtureRandom: RandomNumberGenerator, Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// Uniform in [0, 1).
    public mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    public mutating func uniform(_ range: ClosedRange<Double>) -> Double { range.lowerBound + unit() * (range.upperBound - range.lowerBound) }
    public mutating func int(_ range: ClosedRange<Int>) -> Int { range.lowerBound + Int(next() % UInt64(range.count)) }

    /// A stable 64-bit seed from text (FNV-1a), e.g. a file name or a delivery id.
    public static func seed(_ parts: String...) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for part in parts {
            for byte in part.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3 }
            hash = (hash ^ 0xFF) &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}
