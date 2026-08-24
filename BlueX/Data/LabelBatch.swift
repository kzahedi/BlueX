import Foundation
import SwiftData

/// A drawn batch of posts offered to a human annotator for labelling.
///
/// A batch records its own provenance (`frameJSON`) so that labels collected from it can
/// later be checked for sampling bias: a label from a filtered pool and a label from a
/// uniform draw are indistinguishable once detached from the frame that produced them.
@Model
final class LabelBatch {
    var id: UUID
    var createdAt: Date

    /// The `SamplingFrame` that produced this batch, encoded with a plain `JSONEncoder`
    /// (default key strategy — no `.convertToSnakeCase` or similar). SwiftData cannot query
    /// into a Codable blob, and batches are enumerated rather than filtered by frame, so the
    /// JSON string is the canonical stored form; `frame` below is a convenience decode.
    ///
    /// The key names are a cross-language contract: a companion Python tool filters batches
    /// on the `"kind"` key (`"uniformRandom"` / `"filtered"`), so they must not be renamed or
    /// re-encoded with a different key strategy without updating that tool in lockstep.
    ///
    /// Top-level keys: `kind` (`"uniformRandom"` | `"filtered"`), `outletPK` (Int64?),
    /// `dateFrom`, `dateTo` (Date?), `minThreadReplies`, `maxThreadReplies` (Int?).
    /// `dateFrom`/`dateTo` are encoded by Foundation's default `JSONEncoder` as a **Double of
    /// seconds since the Core Data / Foundation reference date 2001-01-01T00:00:00Z**, NOT
    /// Unix epoch. A Python reader must add 978307200 to convert to Unix epoch seconds
    /// before doing anything with these fields.
    var frameJSON: String

    var poolSizeAtDraw: Int

    /// The random seed used to draw this batch, stored as the bit pattern of a `UInt64`.
    /// SwiftData/Core Data has no unsigned integer storage type, so the raw `Int64` column
    /// holds `Int64(bitPattern: seed)`; use `seed` to read/write the unsigned value directly.
    var seedBitPattern: Int64

    var drawnURIs: [String]
    var labelledURIs: [String]

    /// URIs the annotator deliberately set aside without recording a decision.
    /// Defaulted to `[]` so adding this property is a SwiftData lightweight
    /// migration on existing stores (every pre-existing `LabelBatch` row reads back
    /// with an empty array rather than failing to decode). A skipped URI is excluded
    /// from a normal `openBatch` resume (see `openBatch`'s doc comment) but is never
    /// lost — it stays in this array until the annotator revisits it explicitly and
    /// records a decision, at which point `record` moves it out into `labelledURIs`.
    var skippedURIs: [String] = []

    var passNumber: Int

    /// The batch this one was drawn from, when this is a second (or later) pass over
    /// posts already seen in an earlier batch. `nil` for a first-pass batch.
    var sourceBatchID: UUID?

    var completedAt: Date?

    var seed: UInt64 {
        get { UInt64(bitPattern: seedBitPattern) }
        set { seedBitPattern = Int64(bitPattern: newValue) }
    }

    /// Convenience decode of `frameJSON`. `nil` if the stored JSON fails to decode, which
    /// should not happen for batches created by this app, but a corrupt/foreign row must not
    /// crash the reader.
    var frame: SamplingFrame? {
        do {
            return try JSONDecoder().decode(SamplingFrame.self, from: Data(frameJSON.utf8))
        } catch {
            print("LabelBatch \(id): failed to decode frameJSON: \(error)")
            return nil
        }
    }

    init(frame: SamplingFrame, poolSizeAtDraw: Int, seed: UInt64, drawnURIs: [String],
         passNumber: Int, sourceBatchID: UUID? = nil) {
        self.id = UUID()
        self.createdAt = Date()
        self.frameJSON = String(data: (try? JSONEncoder().encode(frame)) ?? Data(), encoding: .utf8) ?? "{}"
        self.poolSizeAtDraw = poolSizeAtDraw
        self.seedBitPattern = Int64(bitPattern: seed)
        self.drawnURIs = drawnURIs
        self.labelledURIs = []
        self.skippedURIs = []
        self.passNumber = passNumber
        self.sourceBatchID = sourceBatchID
        self.completedAt = nil
    }
}
