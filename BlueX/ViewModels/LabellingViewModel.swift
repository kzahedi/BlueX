import Foundation
import Observation
import SwiftData

/// Drives the human-labelling workflow: drawing a batch, presenting it item by item,
/// recording a decision per item, resuming a partially-labelled batch, drawing a blind
/// second pass over the same URIs, and computing intra-rater agreement once both passes
/// exist.
///
/// **Why human labels are handled so carefully.** These labels are this research
/// project's held-out gold set. Provenance (which frame, which seed, which pass, how
/// long the annotator took) matters as much as the label itself — a label that can't be
/// traced back to a reproducible draw is not usable for measuring anything. The one
/// property this type must never compromise on is blindness: a second pass exists to
/// measure an annotator's *own* consistency, and that measurement is worthless the
/// moment the session shows the annotator their first-pass answer. `openBatch` builds
/// its session exclusively from `AggregateReader.LabellingContext` — a struct with no
/// score/label/model field by construction (see its own doc comment) — and never touches
/// the `Annotation` table when building a session. `agreement` is the only place this
/// type reads `Annotation` rows at all.
///
/// **Concurrency**, following `AuthorStatsViewModel` exactly: the whole type is
/// `@MainActor` so a `createBatch`/`openBatch` call's synchronous prefix can't
/// interleave with another call's; all store I/O for those two runs inside
/// `Task.detached`; `Task.isCancelled` is checked immediately before every state
/// publish, not once at the top of the function.
///
/// **Failure semantics.** A failure to open the underlying store (an unmounted volume,
/// a missing file) surfaces as `loadState == .failed` and leaves the batch/session
/// untouched — never silently treated as an empty pool. Empty pool
/// (`labellingPoolCount == 0`) and an exhausted pool (every candidate URI already drawn
/// by some earlier batch) are different facts and get distinct, named `poolState` cases
/// — conflating them would hide which one actually happened.
@MainActor
@Observable
final class LabellingViewModel {
    enum LoadState: Equatable {
        case idle, loading, loaded
        case failed(String)
    }

    /// Distinct from `LoadState`: a store that opened and queried fine can still have
    /// nothing to draw, and "nothing at all in the frame" (`empty`) is a different fact
    /// from "everything in the frame has already been drawn by an earlier batch"
    /// (`exhausted`) — the former means the frame itself needs to change, the latter
    /// means the labeller has actually worked through the whole pool.
    enum PoolState: Equatable {
        case unknown
        case available(Int)
        case empty
        case exhausted
    }

    enum LabellingError: LocalizedError {
        case batchNotFound

        var errorDescription: String? {
            switch self {
            case .batchNotFound: return "Label batch not found."
            }
        }
    }

    /// Why a call to `record` did not end with a persisted label. Published so the view
    /// can surface it — a silent no-op on a held-out gold set would look to the
    /// annotator like their decision was recorded when it wasn't.
    enum RecordFailure: Equatable, LocalizedError {
        /// The batch itself could not be fetched — the session is broken, not just
        /// this one item; `record` does not advance past it.
        case batchNotFound
        /// The `Post` for the current item no longer exists (e.g. a rescrape deleted
        /// it between draw and record). The item is unrecordable, so `record` advances
        /// past it — like `skip()` — rather than leaving the annotator pressing a dead
        /// key, but the caller must show why.
        case postNotFound(String)
        /// `context.save()` threw. Nothing from this call was persisted — see `record`
        /// for the exact rollback this guarantees.
        case saveFailed(String)

        var errorDescription: String? {
            switch self {
            case .batchNotFound: return "Label batch not found — cannot record."
            case .postNotFound(let uri): return "Post \(uri) no longer exists — skipped."
            case .saveFailed(let message): return "Failed to save label: \(message)"
            }
        }
    }

    /// Opens the `ModelContainer` used internally by `createBatch`/`openBatch` to
    /// persist/read `LabelBatch` rows. Injectable so store-open failure is testable
    /// independently of whatever `AggregateReader` the caller passes in — the two
    /// failure modes (can't open the write-side container vs. can't query the
    /// read-only pool) are otherwise indistinguishable from a test.
    @ObservationIgnored private let containerFactory: () throws -> ModelContainer

    /// Injectable so `record`'s time-to-decide is deterministic in tests. Defaults to
    /// the real wall clock.
    @ObservationIgnored private let clock: () -> Date

    /// Injectable source for a fresh batch seed. Deliberately NOT the deterministic
    /// `SeededGenerator` used inside `LabelSampling.draw` — the seed itself must be
    /// unpredictable so a labeller (or anyone else) cannot anticipate a draw before it
    /// happens; reproducibility comes from *recording* the seed, not from generating it
    /// deterministically. Tests inject a fixed value here to pin the recorded seed.
    @ObservationIgnored private let seedSource: () -> UInt64

    /// Identifies whose decisions `record` writes. Not persisted by this type — the
    /// caller (the labelling view) is responsible for supplying whoever is signed in.
    let annotatorID: String

    init(annotatorID: String,
         containerFactory: @escaping () throws -> ModelContainer = { try BlueXStore.openContainer() },
         clock: @escaping () -> Date = Date.init,
         seedSource: @escaping () -> UInt64 = { UInt64.random(in: UInt64.min...UInt64.max) }) {
        self.annotatorID = annotatorID
        self.containerFactory = containerFactory
        self.clock = clock
        self.seedSource = seedSource
    }

    var loadState: LoadState = .idle
    var poolState: PoolState = .unknown

    /// The batch currently open for labelling, if any.
    private(set) var currentBatchID: UUID?
    private(set) var currentPassNumber: Int = 1

    /// The items presented this session, in presentation order. Built exclusively from
    /// `AggregateReader.LabellingContext` — see the type's doc comment on blindness.
    private(set) var sessionItems: [AggregateReader.LabellingContext] = []
    private(set) var currentIndex: Int = 0

    /// When the item at `currentIndex` was presented — the zero point `record`
    /// measures time-to-decide from. Set by `openBatch` and after every `record`/`skip`.
    @ObservationIgnored private var presentedAt: Date?

    /// Non-nil immediately after a `record` call that did not end with a persisted
    /// label — cleared at the start of every `record` call. The view is expected to
    /// surface this rather than let a failed record look like a silent no-op.
    private(set) var recordError: RecordFailure?

    /// Set-and-checked synchronously at the top of `createBatch`, cleared in `defer` —
    /// a re-entrancy guard the VM owns itself rather than trusting the caller's own
    /// double-click protection (the view has one too, but this must not depend on it).
    @ObservationIgnored private var isCreatingBatch = false

    var currentItem: AggregateReader.LabellingContext? {
        guard currentIndex < sessionItems.count else { return nil }
        return sessionItems[currentIndex]
    }

    var isSessionComplete: Bool { currentIndex >= sessionItems.count }

    // MARK: - Create batch

    /// Draws a fresh batch: pool count and URIs from `reader`, a fresh random seed
    /// (recorded, not deterministic — see `seedSource`), excluding every URI already
    /// drawn by ANY existing batch regardless of pass, then persists the resulting
    /// `LabelBatch`. If nothing is left to draw (empty or fully-exhausted pool), NO
    /// batch is persisted — a 0/0 `LabelBatch` that can never be labelled or completed
    /// would just clutter the batch list forever; `poolState` alone carries that fact.
    func createBatch(frame: SamplingFrame, size: Int, reader: AggregateReader) async {
        guard !isCreatingBatch else { return }
        isCreatingBatch = true
        defer { isCreatingBatch = false }

        loadState = .loading
        let seed = seedSource()
        let containerFactory = self.containerFactory
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                let container = try containerFactory()
                let context = ModelContext(container)
                let poolCount = try reader.labellingPoolCount(frame: frame)
                let poolURIs = try reader.labellingPoolURIs(frame: frame)
                let existing = try context.fetch(FetchDescriptor<LabelBatch>())
                let excluded = Set(existing.flatMap { $0.drawnURIs })
                let drawn = LabelSampling.draw(from: poolURIs, excluding: excluded,
                                                count: size, seed: seed)
                guard !drawn.isEmpty else {
                    // Nothing to draw. `poolCount == 0` means the frame itself is
                    // empty; `poolCount > 0` means every URI in it has already been
                    // drawn by an earlier batch — `poolState` distinguishes the two.
                    return (batchID: UUID?.none, poolCount: poolCount, drawnCount: 0)
                }
                let batch = LabelBatch(frame: frame, poolSizeAtDraw: poolCount, seed: seed,
                                        drawnURIs: drawn, passNumber: 1)
                context.insert(batch)
                try context.save()
                return (batchID: UUID?(batch.id), poolCount: poolCount, drawnCount: drawn.count)
            }.value
            guard !Task.isCancelled else { return }
            if let batchID = result.batchID {
                currentBatchID = batchID
                currentPassNumber = 1
            }
            poolState = Self.poolState(poolCount: result.poolCount, drawnCount: result.drawnCount)
            loadState = .loaded
        } catch {
            guard !Task.isCancelled else { return }
            loadState = .failed(String(describing: error))
        }
    }

    private static func poolState(poolCount: Int, drawnCount: Int) -> PoolState {
        if poolCount == 0 { return .empty }
        if drawnCount == 0 { return .exhausted }
        return .available(poolCount)
    }

    // MARK: - Open / resume batch

    /// Loads the session for an existing batch: unlabelled URIs first (so a partially
    /// labelled batch resumes where it left off), presented in draw order for pass 1
    /// but shuffled per-session for pass 2 — so a pass-2 annotator sees a different
    /// order each time they open it, never the pass-1 order that produced their first
    /// answers, which would let position alone cue recall.
    func openBatch(_ id: UUID, reader: AggregateReader) async {
        loadState = .loading
        let containerFactory = self.containerFactory
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                let container = try containerFactory()
                let context = ModelContext(container)
                let descriptor = FetchDescriptor<LabelBatch>(
                    predicate: #Predicate<LabelBatch> { $0.id == id })
                guard let batch = try context.fetch(descriptor).first else {
                    throw LabellingError.batchNotFound
                }
                let labelled = Set(batch.labelledURIs)
                var unlabelled = batch.drawnURIs.filter { !labelled.contains($0) }
                if batch.passNumber >= 2 {
                    unlabelled.shuffle()
                }
                let contexts = try reader.labellingContext(uris: unlabelled)
                let byURI = Dictionary(uniqueKeysWithValues: contexts.map { ($0.uri, $0) })
                let ordered = unlabelled.compactMap { byURI[$0] }
                return (batchID: batch.id, passNumber: batch.passNumber,
                        drawnCount: batch.drawnURIs.count, items: ordered)
            }.value
            guard !Task.isCancelled else { return }
            currentBatchID = result.batchID
            currentPassNumber = result.passNumber
            sessionItems = result.items
            currentIndex = 0
            presentedAt = clock()
            poolState = result.drawnCount == 0 ? .empty
                : (result.items.isEmpty ? .exhausted : .available(result.items.count))
            loadState = .loaded
        } catch {
            guard !Task.isCancelled else { return }
            loadState = .failed(String(describing: error))
        }
    }

    // MARK: - Record / skip

    /// Records a decision for the current item: writes an `Annotation(stage: "human")`
    /// carrying all four provenance fields, attaches it via `Post.annotations` (fetched
    /// by URI — never a broad fetch), appends the URI to the batch's `labelledURIs`, and
    /// advances to the next item. Sets `completedAt` once every drawn URI in the batch
    /// has a label — not merely once this session's (possibly partial, resumed) item
    /// list is exhausted, since a resumed session may cover only a subset of the batch.
    ///
    /// **Save-failure integrity.** The `Annotation` insert and the `labelledURIs`
    /// append happen against the same in-memory context and are committed by the SAME
    /// `context.save()` call below — so a crash between them is not a state this code
    /// can produce; either both are persisted or neither is. If `save()` throws, every
    /// mutation made in this call (the inserted `Annotation`, the `Post.annotations`
    /// append, `labelledURIs`, `completedAt`) is explicitly rolled back so a failed save
    /// can never silently lose a label while `currentIndex` advances as if it had been
    /// recorded — the item stays current so the annotator can retry, and `recordError`
    /// surfaces what happened.
    func record(_ speechClass: String, note: String?, context: ModelContext) {
        recordError = nil
        guard let item = currentItem, let batchID = currentBatchID else { return }
        let decidedAt = clock()
        let elapsed = presentedAt.map { decidedAt.timeIntervalSince($0) }

        let batchDescriptor = FetchDescriptor<LabelBatch>(
            predicate: #Predicate<LabelBatch> { $0.id == batchID })
        guard let batch = try? context.fetch(batchDescriptor).first else {
            recordError = .batchNotFound
            return
        }

        let uri = item.uri
        let postDescriptor = FetchDescriptor<Post>(predicate: #Predicate<Post> { $0.uri == uri })
        guard let post = try? context.fetch(postDescriptor).first else {
            // The post is gone (e.g. a rescrape deleted it between draw and record).
            // Nothing can be recorded against it — advance past it like `skip()` so the
            // annotator isn't stuck on a dead item, but tell them why.
            recordError = .postNotFound(uri)
            currentIndex += 1
            presentedAt = clock()
            return
        }

        let annotation = Annotation(
            speechClass: speechClass, sentimentScore: 0, detectedLanguage: "",
            modelName: "human", modelVersion: "-", promptHash: "", rawResponse: note ?? "",
            stage: "human", reasoning: note,
            annotatorID: annotatorID, batchID: batchID,
            timeToDecideSeconds: elapsed, passNumber: batch.passNumber)
        context.insert(annotation)
        post.annotations.append(annotation)

        let previousCompletedAt = batch.completedAt
        batch.labelledURIs.append(uri)
        let allLabelled = Set(batch.drawnURIs).isSubset(of: Set(batch.labelledURIs))
        if allLabelled {
            batch.completedAt = decidedAt
        }

        do {
            try context.save()
        } catch {
            // Roll back every in-memory mutation above — a failed save must leave the
            // URI unlabelled, the batch's completion state untouched, and no dangling
            // Annotation, exactly as if `record` had never been called.
            context.delete(annotation)
            if let index = post.annotations.firstIndex(where: { $0 === annotation }) {
                post.annotations.remove(at: index)
            }
            if batch.labelledURIs.last == uri {
                batch.labelledURIs.removeLast()
            }
            batch.completedAt = previousCompletedAt
            recordError = .saveFailed(String(describing: error))
            return
        }

        currentIndex += 1
        presentedAt = clock()
    }

    /// Advances past the current item without recording anything — the URI stays
    /// unlabelled, so a later `openBatch` resume offers it again.
    func skip() {
        guard currentIndex < sessionItems.count else { return }
        currentIndex += 1
        presentedAt = clock()
    }

    // MARK: - Second pass

    /// Draws a second pass over exactly the same URIs as `batchID`'s first pass —
    /// `passNumber: 2`, `sourceBatchID` set to the original. Deliberately does not read
    /// or copy any `Annotation` — the new batch's `labelledURIs` starts empty just like
    /// any other batch, so nothing about the first pass's answers is reachable from it.
    /// Blindness at presentation time is enforced separately, by `openBatch` never
    /// touching `Annotation` when building a session.
    func createSecondPass(of batchID: UUID, context: ModelContext) throws -> UUID {
        let descriptor = FetchDescriptor<LabelBatch>(
            predicate: #Predicate<LabelBatch> { $0.id == batchID })
        guard let original = try context.fetch(descriptor).first else {
            throw LabellingError.batchNotFound
        }
        let frame = original.frame ?? .uniformRandom
        let secondPass = LabelBatch(frame: frame, poolSizeAtDraw: original.poolSizeAtDraw,
                                     seed: original.seed, drawnURIs: original.drawnURIs,
                                     passNumber: 2, sourceBatchID: original.id)
        context.insert(secondPass)
        try context.save()
        return secondPass.id
    }

    // MARK: - Agreement

    /// Pairs pass-1/pass-2 human labels by URI and returns percent agreement + Cohen's
    /// κ (intra-rater, between one annotator's two passes over the same posts) — `nil`
    /// if no second pass exists yet for `batchID`, or the brief's degenerate case
    /// (`AgreementMetrics.compute` returning `nil` for disjoint URI sets).
    func agreement(batchID: UUID, context: ModelContext) throws -> AgreementReport? {
        let pass1Descriptor = FetchDescriptor<LabelBatch>(
            predicate: #Predicate<LabelBatch> { $0.id == batchID })
        guard try context.fetch(pass1Descriptor).first != nil else {
            throw LabellingError.batchNotFound
        }
        let pass2Descriptor = FetchDescriptor<LabelBatch>(
            predicate: #Predicate<LabelBatch> { $0.sourceBatchID == batchID })
        guard let pass2Batch = try context.fetch(pass2Descriptor).first else { return nil }

        let pass1Labels = try humanLabels(batchID: batchID, context: context)
        let pass2Labels = try humanLabels(batchID: pass2Batch.id, context: context)
        return AgreementMetrics.compute(pass1: pass1Labels, pass2: pass2Labels)
    }

    /// URI → speechClass for every human annotation recorded under `batchID`.
    private func humanLabels(batchID: UUID, context: ModelContext) throws -> [String: String] {
        let descriptor = FetchDescriptor<Annotation>(
            predicate: #Predicate<Annotation> { $0.batchID == batchID && $0.stage == "human" })
        let annotations = try context.fetch(descriptor)
        var labels: [String: String] = [:]
        for annotation in annotations {
            guard let uri = annotation.post?.uri else { continue }
            labels[uri] = annotation.speechClass
        }
        return labels
    }
}
