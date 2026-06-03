import Foundation

/// Deterministic, seedable RNG (SplitMix64). `SystemRandomNumberGenerator` is not
/// seedable, so we use this for reproducible sampling — the same seed + same input
/// pool always selects the same subset, which makes the sampling methodology
/// documentable and the selection unit-testable.
struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// Allocates a sample budget across strata (weeks) using largest-remainder
/// apportionment with a floor of 1 per non-empty stratum (when the budget allows),
/// capped at each stratum's available count.
enum StratifiedSampler {

    /// - Parameters:
    ///   - counts: stratum key → number of available items in that stratum
    ///   - total: total budget to allocate
    /// - Returns: stratum key → number to sample. Sum equals `min(total, Σ counts)`.
    ///   Empty strata (count 0) always get 0. Non-empty strata get ≥1 when the
    ///   budget is large enough to cover every non-empty stratum.
    static func allocate<Key: Hashable & Comparable>(counts: [Key: Int], total: Int) -> [Key: Int] {
        let nonEmpty = counts.filter { $0.value > 0 }
        if nonEmpty.isEmpty || total <= 0 { return [:] }

        let available = nonEmpty.values.reduce(0, +)
        let target = min(total, available)

        // Take-all shortcut.
        if target >= available {
            return nonEmpty
        }

        // Deterministic key ordering for tie-breaking (largest count first, then key).
        let keysByPriority = nonEmpty.keys.sorted { lhs, rhs in
            let cl = nonEmpty[lhs]!, cr = nonEmpty[rhs]!
            return cl != cr ? cl > cr : lhs < rhs
        }

        var alloc: [Key: Int] = [:]

        // Case A: budget too small to give every non-empty week 1 — give 1 to the
        // `target` largest weeks, 0 to the rest.
        if target <= nonEmpty.count {
            for key in keysByPriority.prefix(target) { alloc[key] = 1 }
            for key in keysByPriority.dropFirst(target) { alloc[key] = 0 }
            return alloc
        }

        // Case B (normal): floor of 1 each, then distribute the remainder by
        // largest-remainder, capped at each week's available count.
        for key in nonEmpty.keys { alloc[key] = 1 }
        var remaining = target - nonEmpty.count

        // Ideal additional allocation (beyond the floor) per week, proportional to count.
        // Cap headroom is count-1 (already gave 1). Tuple fields: key, floorAdd, remainder, cap.
        let extraBudgetBase = Double(remaining)
        let totalCount = Double(available)
        var fracs: [(key: Key, floorAdd: Int, remainder: Double, cap: Int)] = nonEmpty.map { (key, count) in
            let ideal = extraBudgetBase * Double(count) / totalCount
            let fl = Int(ideal.rounded(.down))
            return (key: key, floorAdd: fl, remainder: ideal - Double(fl), cap: count - 1)
        }

        // Apply floor additions, respecting caps.
        for f in fracs {
            let add = min(f.floorAdd, f.cap)
            alloc[f.key]! += add
            remaining -= add
        }

        // Distribute leftover one unit at a time in largest-remainder order, skipping
        // capped-out weeks (degrades to round-robin over that order once caps force
        // multiple units onto a week — the sum stays exact either way).
        fracs.sort { lhs, rhs in
            lhs.remainder != rhs.remainder ? lhs.remainder > rhs.remainder
                                           : (nonEmpty[lhs.key]! > nonEmpty[rhs.key]!)
        }
        var idx = 0
        // Each full pass over `fracs` places at least one unit while any non-capped
        // week remains (target ≤ available guarantees headroom), so this bound is ample.
        var safety = (remaining + 1) * (fracs.count + 1)
        while remaining > 0 && safety > 0 {
            let f = fracs[idx % fracs.count]
            if alloc[f.key]! < nonEmpty[f.key]! {   // not yet capped
                alloc[f.key]! += 1
                remaining -= 1
            }
            idx += 1
            safety -= 1
        }

        return alloc
    }
}
