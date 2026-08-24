import Foundation

/// The recorded provenance of a labelling batch. A label without its frame is unusable
/// for measurement: labels from a filtered pool and a uniform draw are indistinguishable
/// afterwards, and any prevalence estimate across them is silently biased.
struct SamplingFrame: Codable, Equatable {
    enum Kind: String, Codable { case uniformRandom, filtered, stratified }
    var kind: Kind
    var outletPK: Int64?
    var dateFrom: Date?
    var dateTo: Date?
    var minThreadReplies: Int?
    var maxThreadReplies: Int?

    /// The `stratified` kind's own fields. Deliberately optional with a `nil` default
    /// so this is source- and JSON-compatible with every `uniformRandom`/`filtered`
    /// frame that predates them: existing encoded frames simply lack these keys, and
    /// Codable's synthesized `decodeIfPresent` for an `Optional`-typed stored property
    /// leaves them `nil` rather than failing to decode.
    ///
    /// The identifier of the stratum a batch was drawn from (e.g. `"tox_top_1"`).
    var stratumID: String? = nil
    /// Verbatim predicate text from the frame file (e.g. `"tox_pct >= 99.0000"`) —
    /// provenance the annotator may see (it says *how* posts were chosen), never a
    /// score (see the frame file's own blindness discussion).
    var stratumDefinition: String? = nil
    /// The stratum's full population size in the corpus — the number the weight
    /// N_h/N is computed from by the Python-side weighted estimator.
    var populationSize: Int? = nil
    /// SHA-256 of the frame file this stratum was drawn from, hex-encoded. Used both
    /// as import-dedup key (with `stratumID`) and by analyses to pin which committee
    /// scoring the strata were cut from.
    var frameFileSHA256: String? = nil
    /// The Python-side random seed the frame file's per-stratum URI subsample was
    /// drawn with.
    var drawSeed: UInt64? = nil

    static let uniformRandom = SamplingFrame(kind: .uniformRandom, outletPK: nil,
        dateFrom: nil, dateTo: nil, minThreadReplies: nil, maxThreadReplies: nil)

    static func stratified(stratumID: String, stratumDefinition: String, populationSize: Int,
                            frameFileSHA256: String, drawSeed: UInt64) -> SamplingFrame {
        SamplingFrame(kind: .stratified, outletPK: nil, dateFrom: nil, dateTo: nil,
                      minThreadReplies: nil, maxThreadReplies: nil,
                      stratumID: stratumID, stratumDefinition: stratumDefinition,
                      populationSize: populationSize, frameFileSHA256: frameFileSHA256,
                      drawSeed: drawSeed)
    }

    var isUniformRandom: Bool { self == .uniformRandom }
}
