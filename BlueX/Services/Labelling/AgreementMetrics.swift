import Foundation

/// Agreement between the two passes of the *same* annotator over the *same* URIs —
/// intra-rater agreement, not inter-rater. Weaker evidence of label quality than
/// inter-rater agreement (it only shows an annotator is consistent with themselves,
/// not that two independent people agree), so `agreement(batchID:)` callers must
/// present this with that caveat rather than as a general reliability figure.
struct AgreementReport: Equatable {
    let n: Int
    let percentAgreement: Double
    let cohensKappa: Double   // between the two passes of the same annotator:
                              // intra-rater kappa. Weaker than inter-rater; report as such.
}

enum AgreementMetrics {
    /// κ = (p_o − p_e) / (1 − p_e); p_e from each pass's marginal class distribution.
    /// Returns kappa = 1 when both passes agree perfectly even if p_e == 1 (single
    /// class used throughout) — that degenerate case must not divide by zero.
    static func compute(pass1: [String: String], pass2: [String: String]) -> AgreementReport? {
        let keys = Set(pass1.keys).intersection(pass2.keys)
        guard !keys.isEmpty else { return nil }
        let pairs = keys.map { (pass1[$0]!, pass2[$0]!) }
        let n = Double(pairs.count)
        let po = Double(pairs.filter { $0.0 == $0.1 }.count) / n
        let classes = Set(pairs.flatMap { [$0.0, $0.1] })
        let pe = classes.reduce(0.0) { acc, c in
            let m1 = Double(pairs.filter { $0.0 == c }.count) / n
            let m2 = Double(pairs.filter { $0.1 == c }.count) / n
            return acc + m1 * m2
        }
        let kappa = pe >= 1.0 ? (po >= 1.0 ? 1.0 : 0.0) : (po - pe) / (1 - pe)
        return AgreementReport(n: pairs.count, percentAgreement: po, cohensKappa: kappa)
    }
}
