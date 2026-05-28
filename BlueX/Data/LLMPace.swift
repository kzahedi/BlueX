// BlueX/Data/LLMPace.swift
import Foundation

/// How aggressively the LLM annotation pass hits the local Ollama runner. Longer
/// pauses between posts let the Apple Silicon SoC cool, drop fan noise, and avoid
/// thermal throttling on multi-hour runs.
enum LLMPace: String, CaseIterable, Identifiable, Sendable {
    case burst    // no delay — finish as fast as possible
    case steady   // 500 ms between posts (default)
    case gentle   // 2 s between posts — overnight / unattended

    var id: String { rawValue }

    /// Base delay applied after each post, before thermal back-off is added.
    var baseDelayNanoseconds: UInt64 {
        switch self {
        case .burst:  return 0
        case .steady: return 500_000_000
        case .gentle: return 2_000_000_000
        }
    }

    var label: String {
        switch self {
        case .burst:  return "Burst (no pause)"
        case .steady: return "Steady (0.5 s)"
        case .gentle: return "Gentle (2 s)"
        }
    }
}

/// Extra cool-down inserted automatically when the system reports heat pressure.
/// Returns 0 for nominal / fair, several seconds for serious / critical.
enum ThermalBackoff {
    static func extraDelayNanoseconds(for state: ProcessInfo.ThermalState) -> UInt64 {
        switch state {
        case .nominal, .fair: return 0
        case .serious:        return 3_000_000_000
        case .critical:       return 10_000_000_000
        @unknown default:     return 0
        }
    }
}
