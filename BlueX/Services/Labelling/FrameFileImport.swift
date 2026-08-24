import Foundation
import CryptoKit
import SwiftData

/// Imports a committee-produced stratified frame file (see the design doc,
/// `docs/superpowers/specs/2026-08-24-stratified-labelling-frame-design.md`, §2) into
/// one `LabelBatch` per stratum.
///
/// **The blindness guarantee lives here.** The app never runs the committee scoring —
/// it only ever reads a file the committee tooling (Python) produced, and that file is
/// an opaque list of URIs plus stratum metadata: no score, ever. This importer is the
/// one place that file is parsed, and it refuses (all-or-nothing — see below) the
/// moment it sees anything that looks like a score sneaking in, rather than trusting
/// every future frame-file generator to keep honouring that contract.
///
/// **All-or-nothing.** Every stratum in the file is validated BEFORE any `LabelBatch`
/// is inserted into `context`. A file that fails validation on stratum 6 of 8 creates
/// ZERO batches, not five — a partial import would silently corrupt the "one post,
/// one batch" invariant the weighted estimator depends on.
enum FrameFileImport {

    struct ImportResult {
        /// IDs of the batches newly created by this call. Empty when every stratum in
        /// the file had already been imported (same `frameFileSHA256` + `stratumID`).
        let createdBatchIDs: [UUID]
        var skippedAlreadyImported: Bool { createdBatchIDs.isEmpty }
    }

    enum ImportError: LocalizedError {
        case notAnObject
        case missingStrata
        case missingCommitteeSHA256
        case missingStratumID
        case missingPopulationSize(stratumID: String)
        case invalidPopulationSize(stratumID: String)
        case missingURIs(stratumID: String)
        case emptyStratum(stratumID: String)
        case scoredURIEntry(stratumID: String)
        case duplicateURIAcrossStrata(uri: String, firstStratum: String, secondStratum: String)

        var errorDescription: String? {
            switch self {
            case .notAnObject:
                return "Frame file is not a JSON object."
            case .missingStrata:
                return "Frame file has no 'strata' array."
            case .missingCommitteeSHA256:
                return "Frame file is missing committee.db_sha256 — refusing to import an " +
                       "unpinned frame."
            case .missingStratumID:
                return "A stratum in the frame file is missing its 'id'."
            case .missingPopulationSize(let id):
                return "Stratum '\(id)' is missing 'population_size' — the estimator " +
                       "cannot compute a weight without it."
            case .invalidPopulationSize(let id):
                return "Stratum '\(id)' has a zero or invalid 'population_size'."
            case .missingURIs(let id):
                return "Stratum '\(id)' has no 'uris' array."
            case .emptyStratum(let id):
                return "Stratum '\(id)' has an empty URI list."
            case .scoredURIEntry(let id):
                return "Stratum '\(id)' contains a URI entry that is not a plain string — " +
                       "the frame file must contain groupings only, never a score. Refusing " +
                       "to import so a leaked score can never reach the labelling view."
            case .duplicateURIAcrossStrata(let uri, let first, let second):
                return "URI '\(uri)' appears in both stratum '\(first)' and '\(second)' — " +
                       "a post must belong to exactly one batch for per-stratum precision " +
                       "to be interpretable."
            }
        }
    }

    private struct StratumDraft {
        let id: String
        let definition: String
        let populationSize: Int
        let uris: [String]
    }

    /// Parses, validates, and imports `url` into `context`. Every stratum is fully
    /// validated before anything is inserted — see the type's doc comment. Returns
    /// the batch IDs created; an empty list (not an error) means the whole file had
    /// already been imported.
    @discardableResult
    static func importFrameFile(at url: URL, context: ModelContext) throws -> ImportResult {
        let data = try Data(contentsOf: url)
        let fileSHA256 = sha256Hex(data)

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ImportError.notAnObject
        }
        guard let committee = root["committee"] as? [String: Any],
              let dbSHA256 = committee["db_sha256"] as? String, !dbSHA256.isEmpty else {
            throw ImportError.missingCommitteeSHA256
        }
        guard let strataRaw = root["strata"] as? [[String: Any]] else {
            throw ImportError.missingStrata
        }
        let seed = uint64Value(root["seed"]) ?? 0

        var drafts: [StratumDraft] = []
        var firstStratumForURI: [String: String] = [:]

        for stratumRaw in strataRaw {
            guard let id = stratumRaw["id"] as? String, !id.isEmpty else {
                throw ImportError.missingStratumID
            }
            let definition = stratumRaw["definition"] as? String ?? ""

            guard let popSizeRaw = stratumRaw["population_size"], !(popSizeRaw is NSNull) else {
                throw ImportError.missingPopulationSize(stratumID: id)
            }
            guard let populationSize = intValue(popSizeRaw), populationSize > 0 else {
                throw ImportError.invalidPopulationSize(stratumID: id)
            }

            guard let urisRaw = stratumRaw["uris"] as? [Any] else {
                throw ImportError.missingURIs(stratumID: id)
            }
            guard !urisRaw.isEmpty else {
                throw ImportError.emptyStratum(stratumID: id)
            }

            var uris: [String] = []
            for entry in urisRaw {
                guard let uri = entry as? String else {
                    throw ImportError.scoredURIEntry(stratumID: id)
                }
                uris.append(uri)
            }

            for uri in uris {
                if let firstID = firstStratumForURI[uri], firstID != id {
                    throw ImportError.duplicateURIAcrossStrata(
                        uri: uri, firstStratum: firstID, secondStratum: id)
                }
                firstStratumForURI[uri] = id
            }

            drafts.append(StratumDraft(id: id, definition: definition,
                                        populationSize: populationSize, uris: uris))
        }

        // Every stratum validated. Only now touch `context` — dedup on
        // (frameFileSHA256, stratumID) so re-importing the same file is a no-op.
        let existingKeys = try existingStratifiedKeys(context: context)

        var createdIDs: [UUID] = []
        for draft in drafts {
            let key = fileSHA256 + "\u{0}" + draft.id
            guard !existingKeys.contains(key) else { continue }

            let frame = SamplingFrame.stratified(
                stratumID: draft.id, stratumDefinition: draft.definition,
                populationSize: draft.populationSize, frameFileSHA256: fileSHA256,
                drawSeed: seed)
            let batch = LabelBatch(frame: frame, poolSizeAtDraw: draft.populationSize,
                                   seed: seed, drawnURIs: draft.uris, passNumber: 1)
            context.insert(batch)
            createdIDs.append(batch.id)
        }

        if !createdIDs.isEmpty {
            try context.save()
        }

        return ImportResult(createdBatchIDs: createdIDs)
    }

    private static func existingStratifiedKeys(context: ModelContext) throws -> Set<String> {
        let existing = try context.fetch(FetchDescriptor<LabelBatch>())
        return Set(existing.compactMap { batch -> String? in
            guard let frame = batch.frame, frame.kind == .stratified,
                  let sha = frame.frameFileSHA256, let stratumID = frame.stratumID else {
                return nil
            }
            return sha + "\u{0}" + stratumID
        })
    }

    private static func intValue(_ any: Any) -> Int? {
        if let number = any as? NSNumber { return number.intValue }
        if let string = any as? String { return Int(string) }
        return nil
    }

    private static func uint64Value(_ any: Any?) -> UInt64? {
        guard let any else { return nil }
        if let number = any as? NSNumber {
            let doubleValue = number.doubleValue
            guard doubleValue >= 0 else { return nil }
            return number.uint64Value
        }
        if let string = any as? String { return UInt64(string) }
        return nil
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }
}
