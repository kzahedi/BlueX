import Foundation

/// The recorded provenance of a labelling batch. A label without its frame is unusable
/// for measurement: labels from a filtered pool and a uniform draw are indistinguishable
/// afterwards, and any prevalence estimate across them is silently biased.
struct SamplingFrame: Codable, Equatable {
    enum Kind: String, Codable { case uniformRandom, filtered }
    var kind: Kind
    var outletPK: Int64?
    var dateFrom: Date?
    var dateTo: Date?
    var minThreadReplies: Int?
    var maxThreadReplies: Int?

    static let uniformRandom = SamplingFrame(kind: .uniformRandom, outletPK: nil,
        dateFrom: nil, dateTo: nil, minThreadReplies: nil, maxThreadReplies: nil)

    var isUniformRandom: Bool { self == .uniformRandom }
}
