import Foundation

/// SplitMix64 — deterministic across runs and platforms, unlike
/// SystemRandomNumberGenerator, which is unseedable by design. Determinism is a spec
/// requirement: the recorded seed must reproduce the draw.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

enum LabelSampling {
    /// Deterministic sample of `count` URIs. Sorts the pool first so the result depends
    /// only on (pool contents, exclusions, count, seed) — never on SQL row order.
    static func draw(from pool: [String], excluding drawn: Set<String>,
                     count: Int, seed: UInt64) -> [String] {
        var candidates = pool.filter { !drawn.contains($0) }.sorted()
        guard candidates.count > count else { return candidates }
        var rng = SeededGenerator(seed: seed)
        // Partial Fisher–Yates: fix positions 0..<count.
        for i in 0..<count {
            let j = Int(rng.next() % UInt64(candidates.count - i)) + i
            candidates.swapAt(i, j)
        }
        return Array(candidates.prefix(count))
    }
}
