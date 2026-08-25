import XCTest
import SwiftData
@testable import BlueX

/// File-backed `ModelContainer` deliberately (not in-memory), and the SAME file is also
/// opened read-only through a real `AggregateReader` — the pattern established by
/// `AuthorBackfillTests.makeFileBackedContainer()`. `Post` rows are inserted via the
/// real SwiftData `ModelContext`, saved, and the reader then queries the committed rows
/// through raw SQL against the Core Data-generated tables. This is the only way to
/// exercise `LabellingViewModel` end to end: it needs a real `ModelContext` for
/// `LabelBatch`/`Annotation`/`Post` and a real `AggregateReader` for the pool/context
/// queries, both against data that actually agrees with each other.
@MainActor
final class LabellingViewModelTests: XCTestCase {
    var container: ModelContainer!
    var context: ModelContext!
    var storeDir: URL!
    var storeURL: URL!
    var reader: AggregateReader!

    /// Number of ordinary reply posts seeded under one root — the labelling pool.
    private static let replyCount = 10

    override func setUpWithError() throws {
        storeDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("bluex-labelling-vm-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        storeURL = storeDir.appendingPathComponent("test.store")

        let config = ModelConfiguration(schema: BlueXSchema.all, url: storeURL,
                                         allowsSave: true, cloudKitDatabase: .none)
        container = try ModelContainer(for: BlueXSchema.all, configurations: config)
        context = ModelContext(container)

        let root = Post(uri: "at://root", text: "root post", createdAt: Date(timeIntervalSince1970: 0),
                         authorDID: "did:root", authorHandle: "root.test",
                         parentURI: nil, rootURI: "at://root", isRootPost: true, depth: 0)
        context.insert(root)
        for i in 0..<Self.replyCount {
            let uri = "at://reply\(i)"
            let post = Post(uri: uri, text: "reply \(i)",
                             createdAt: Date(timeIntervalSince1970: Double(i + 1)),
                             authorDID: "did:r\(i)", authorHandle: "r\(i).test",
                             parentURI: "at://root", rootURI: "at://root",
                             isRootPost: false, depth: 1)
            context.insert(post)
        }
        try context.save()

        reader = try AggregateReader(storeURL: storeURL)
    }

    override func tearDownWithError() throws {
        reader = nil
        container = nil
        context = nil
        if let storeDir { try? FileManager.default.removeItem(at: storeDir) }
    }

    private func makeViewModel(annotatorID: String = "anna", seed: UInt64 = 1,
                                clock: @escaping () -> Date = Date.init) -> LabellingViewModel {
        let container = self.container!
        return LabellingViewModel(annotatorID: annotatorID,
                                   containerFactory: { container },
                                   clock: clock,
                                   seedSource: { seed })
    }

    // MARK: - createBatch

    func testCreateBatchRecordsFrameSeedAndPoolSize() async throws {
        let vm = makeViewModel(seed: 999)
        await vm.createBatch(frame: .uniformRandom, size: 5, reader: reader)

        guard case .loaded = vm.loadState else {
            return XCTFail("expected .loaded, got \(vm.loadState)")
        }
        let batchID = try XCTUnwrap(vm.currentBatchID)
        let descriptor = FetchDescriptor<LabelBatch>(predicate: #Predicate<LabelBatch> { $0.id == batchID })
        let batch = try XCTUnwrap(context.fetch(descriptor).first)

        XCTAssertEqual(batch.frame, .uniformRandom)
        XCTAssertEqual(batch.seed, 999)
        XCTAssertEqual(batch.poolSizeAtDraw, Self.replyCount)
        XCTAssertEqual(batch.drawnURIs.count, 5)
        XCTAssertEqual(batch.passNumber, 1)
    }

    func testSecondBatchFromSamePoolExcludesFirstBatchsURIs() async throws {
        let vm1 = makeViewModel(seed: 1)
        await vm1.createBatch(frame: .uniformRandom, size: 6, reader: reader)
        let batch1ID = try XCTUnwrap(vm1.currentBatchID)
        let batch1 = try XCTUnwrap(context.fetch(
            FetchDescriptor<LabelBatch>(predicate: #Predicate<LabelBatch> { $0.id == batch1ID })).first)
        XCTAssertEqual(batch1.drawnURIs.count, 6)

        let vm2 = makeViewModel(seed: 2)
        await vm2.createBatch(frame: .uniformRandom, size: 6, reader: reader)
        let batch2ID = try XCTUnwrap(vm2.currentBatchID)
        let batch2 = try XCTUnwrap(context.fetch(
            FetchDescriptor<LabelBatch>(predicate: #Predicate<LabelBatch> { $0.id == batch2ID })).first)

        // Only 4 of the 10 replies remain after batch1 drew 6.
        XCTAssertEqual(batch2.drawnURIs.count, 4)
        XCTAssertTrue(Set(batch1.drawnURIs).isDisjoint(with: Set(batch2.drawnURIs)))
    }

    /// An empty frame (nothing at or before the epoch — every reply is after it)
    /// must not persist a `LabelBatch` at all; `poolState` alone carries the fact.
    func testCreateBatchOnEmptyPoolPersistsNoBatchAndPublishesEmpty() async throws {
        let vm = makeViewModel(seed: 71)
        let emptyFrame = SamplingFrame(kind: .filtered, outletPK: nil,
                                        dateFrom: nil, dateTo: Date(timeIntervalSince1970: 0),
                                        minThreadReplies: nil, maxThreadReplies: nil)
        await vm.createBatch(frame: emptyFrame, size: 5, reader: reader)

        guard case .loaded = vm.loadState else {
            return XCTFail("expected .loaded, got \(vm.loadState)")
        }
        XCTAssertEqual(vm.poolState, .empty)
        XCTAssertNil(vm.currentBatchID)
        let batches = try context.fetch(FetchDescriptor<LabelBatch>())
        XCTAssertTrue(batches.isEmpty, "no LabelBatch row should be persisted for an empty pool")
    }

    /// Once an earlier batch has drawn every URI in the pool, a second `createBatch`
    /// call must not persist a 0/0 `LabelBatch` — it should publish `.exhausted` and
    /// leave the batch list exactly as it was.
    func testCreateBatchOnExhaustedPoolPersistsNoBatchAndPublishesExhausted() async throws {
        let vm1 = makeViewModel(seed: 72)
        await vm1.createBatch(frame: .uniformRandom, size: Self.replyCount, reader: reader)
        XCTAssertEqual(try context.fetch(FetchDescriptor<LabelBatch>()).count, 1)

        let vm2 = makeViewModel(seed: 73)
        await vm2.createBatch(frame: .uniformRandom, size: 5, reader: reader)

        guard case .loaded = vm2.loadState else {
            return XCTFail("expected .loaded, got \(vm2.loadState)")
        }
        XCTAssertEqual(vm2.poolState, .exhausted)
        XCTAssertNil(vm2.currentBatchID)
        let batches = try context.fetch(FetchDescriptor<LabelBatch>())
        XCTAssertEqual(batches.count, 1, "no second LabelBatch row should be persisted once exhausted")
    }

    /// The VM must not rely on its caller to prevent a double-click: a second
    /// `createBatch` call while the first is still in flight is a synchronous no-op.
    func testCreateBatchIgnoresReentrantCallWhileInFlight() async throws {
        let vm = makeViewModel(seed: 81)
        async let first: Void = vm.createBatch(frame: .uniformRandom, size: 3, reader: reader)
        async let second: Void = vm.createBatch(frame: .uniformRandom, size: 3, reader: reader)
        _ = await (first, second)

        let batches = try context.fetch(FetchDescriptor<LabelBatch>())
        XCTAssertEqual(batches.count, 1, "a re-entrant call while one is in flight must be a no-op")
    }

    // MARK: - openBatch / resume

    func testResumePresentsOnlyUnlabelledURIs() async throws {
        let vm = makeViewModel(seed: 5)
        await vm.createBatch(frame: .uniformRandom, size: 4, reader: reader)
        let batchID = try XCTUnwrap(vm.currentBatchID)

        await vm.openBatch(batchID, reader: reader)
        XCTAssertEqual(vm.sessionItems.count, 4)
        let firstURI = try XCTUnwrap(vm.currentItem?.uri)

        vm.record("neutral", note: nil, context: context)

        let vm2 = makeViewModel(seed: 5)
        await vm2.openBatch(batchID, reader: reader)
        XCTAssertEqual(vm2.sessionItems.count, 3)
        XCTAssertFalse(vm2.sessionItems.contains { $0.uri == firstURI })
    }

    // MARK: - record

    func testRecordPersistsHumanStageAndAllProvenanceFields() async throws {
        var ticks: [Date] = [
            Date(timeIntervalSince1970: 0),   // presentedAt set by openBatch
            Date(timeIntervalSince1970: 5),   // decidedAt inside record — elapsed == 5
            Date(timeIntervalSince1970: 20),  // presentedAt reset after record
        ]
        let clock: () -> Date = { ticks.isEmpty ? Date(timeIntervalSince1970: 999) : ticks.removeFirst() }

        let vm = makeViewModel(annotatorID: "anna", seed: 7, clock: clock)
        await vm.createBatch(frame: .uniformRandom, size: 2, reader: reader)
        let batchID = try XCTUnwrap(vm.currentBatchID)
        await vm.openBatch(batchID, reader: reader)
        let firstURI = try XCTUnwrap(vm.currentItem?.uri)

        vm.record("hate", note: "test note", context: context)

        let annotations = try context.fetch(
            FetchDescriptor<Annotation>(predicate: #Predicate<Annotation> { $0.batchID == batchID }))
        XCTAssertEqual(annotations.count, 1)
        let annotation = try XCTUnwrap(annotations.first)

        XCTAssertEqual(annotation.stage, "human")
        XCTAssertEqual(annotation.speechClass, "hate")
        XCTAssertEqual(annotation.annotatorID, "anna")
        XCTAssertEqual(annotation.batchID, batchID)
        XCTAssertEqual(annotation.passNumber, 1)
        XCTAssertEqual(try XCTUnwrap(annotation.timeToDecideSeconds), 5.0, accuracy: 1e-9)
        XCTAssertEqual(annotation.post?.uri, firstURI)
        // Every human label recorded from now on is judged against the current
        // canonical definitions — never left at the pre-existing-row default of 0.
        XCTAssertEqual(annotation.definitionVersion, LabellingDefinitions.version)
    }

    // MARK: - Stratified batches open through the ordinary session flow

    /// A batch drawn by `FrameFileImport` (not `createBatch`) must open and record
    /// labels exactly like any other batch, and its `Annotation` rows must carry the
    /// batch/pass provenance — proving the stratified path shares the same session
    /// machinery as uniformRandom/filtered rather than a bespoke one.
    func testStratifiedBatchOpensAndRecordsLabelsThroughNormalFlow() async throws {
        let frame = SamplingFrame.stratified(
            stratumID: "tox_top_1", stratumDefinition: "tox_pct >= 99.0000",
            populationSize: 20844, frameFileSHA256: "deadbeef", drawSeed: 20260824)
        let uris = (0..<Self.replyCount).map { "at://reply\($0)" }
        let batch = LabelBatch(frame: frame, poolSizeAtDraw: 20844, seed: 20260824,
                                drawnURIs: uris, passNumber: 1)
        let batchID = batch.id
        context.insert(batch)
        try context.save()

        let vm = makeViewModel(annotatorID: "anna", seed: 1)
        await vm.openBatch(batchID, reader: reader)

        guard case .loaded = vm.loadState else {
            return XCTFail("expected .loaded, got \(vm.loadState)")
        }
        XCTAssertEqual(vm.sessionItems.count, Self.replyCount)

        vm.record("hate", note: nil, context: context)

        let annotations = try context.fetch(
            FetchDescriptor<Annotation>(predicate: #Predicate<Annotation> { $0.batchID == batchID }))
        XCTAssertEqual(annotations.count, 1)
        let annotation = try XCTUnwrap(annotations.first)
        XCTAssertEqual(annotation.stage, "human")
        XCTAssertEqual(annotation.annotatorID, "anna")
        XCTAssertEqual(annotation.batchID, batchID)
        XCTAssertEqual(annotation.passNumber, 1)

        let refetched = try XCTUnwrap(context.fetch(FetchDescriptor<LabelBatch>(
            predicate: #Predicate<LabelBatch> { $0.id == batchID })).first)
        XCTAssertEqual(refetched.labelledURIs.count, 1)
        XCTAssertEqual(refetched.frame?.kind, .stratified)
        XCTAssertEqual(refetched.frame?.stratumID, "tox_top_1")
    }

    func testCompletedAtSetOnLastItem() async throws {
        let vm = makeViewModel(seed: 11)
        await vm.createBatch(frame: .uniformRandom, size: 1, reader: reader)
        let batchID = try XCTUnwrap(vm.currentBatchID)
        await vm.openBatch(batchID, reader: reader)
        XCTAssertEqual(vm.sessionItems.count, 1)

        vm.record("neutral", note: nil, context: context)

        let batch = try XCTUnwrap(context.fetch(
            FetchDescriptor<LabelBatch>(predicate: #Predicate<LabelBatch> { $0.id == batchID })).first)
        XCTAssertNotNil(batch.completedAt)
    }

    func testSkipPersistsURIIntoSkippedURIsAndAdvances() async throws {
        let vm = makeViewModel(seed: 13)
        await vm.createBatch(frame: .uniformRandom, size: 2, reader: reader)
        let batchID = try XCTUnwrap(vm.currentBatchID)
        await vm.openBatch(batchID, reader: reader)
        let firstURI = try XCTUnwrap(vm.currentItem?.uri)

        vm.skip(context: context)
        XCTAssertEqual(vm.currentIndex, 1)

        let annotations = try context.fetch(FetchDescriptor<Annotation>())
        XCTAssertTrue(annotations.isEmpty, "a skip must never write an Annotation")

        let batch = try XCTUnwrap(context.fetch(
            FetchDescriptor<LabelBatch>(predicate: #Predicate<LabelBatch> { $0.id == batchID })).first)
        XCTAssertEqual(batch.skippedURIs, [firstURI])
        XCTAssertTrue(batch.labelledURIs.isEmpty)
    }

    /// A resumed session must never re-offer a URI that was deliberately skipped —
    /// that is exactly the bug this task fixes (`openBatch` must filter by
    /// `labelledURIs ∪ skippedURIs`, not `labelledURIs` alone).
    func testResumeAfterSkipNeverReOffersTheSkippedURI() async throws {
        let vm = makeViewModel(seed: 13)
        await vm.createBatch(frame: .uniformRandom, size: 2, reader: reader)
        let batchID = try XCTUnwrap(vm.currentBatchID)
        await vm.openBatch(batchID, reader: reader)
        let firstURI = try XCTUnwrap(vm.currentItem?.uri)

        vm.skip(context: context)

        let vm2 = makeViewModel(seed: 13)
        await vm2.openBatch(batchID, reader: reader)
        XCTAssertFalse(vm2.sessionItems.contains { $0.uri == firstURI },
                        "a skipped URI must not be re-offered by an ordinary resume")
    }

    /// Mirrors `testSaveFailureLeavesNothingPersistedAndDoesNotAdvance` exactly, for
    /// `skip()`: a failed save must roll back the `skippedURIs` append, leave
    /// `currentIndex` untouched, and publish `.saveFailed`.
    func testSkipSaveFailureRollsBackAppendAndDoesNotAdvance() async throws {
        let vm = makeViewModel(seed: 13)
        await vm.createBatch(frame: .uniformRandom, size: 2, reader: reader)
        let batchID = try XCTUnwrap(vm.currentBatchID)
        await vm.openBatch(batchID, reader: reader)
        XCTAssertEqual(vm.sessionItems.count, 2)

        let readOnlyConfig = ModelConfiguration(schema: BlueXSchema.all, url: storeURL,
                                                 allowsSave: false, cloudKitDatabase: .none)
        let readOnlyContainer = try ModelContainer(for: BlueXSchema.all, configurations: readOnlyConfig)
        let readOnlyContext = ModelContext(readOnlyContainer)

        vm.skip(context: readOnlyContext)

        let failure = try XCTUnwrap(vm.recordError)
        guard case .saveFailed = failure else {
            return XCTFail("expected .saveFailed, got \(failure)")
        }
        XCTAssertEqual(vm.currentIndex, 0, "must not advance on a failed save")

        let batch = try XCTUnwrap(context.fetch(
            FetchDescriptor<LabelBatch>(predicate: #Predicate<LabelBatch> { $0.id == batchID })).first)
        XCTAssertTrue(batch.skippedURIs.isEmpty, "skippedURIs must not be appended on a failed save")
    }

    // MARK: - Revisit skipped

    /// The revisit path offers exactly the skipped URIs, and deciding one removes it
    /// from `skippedURIs` and adds it to `labelledURIs`.
    func testRevisitSkippedOffersExactlySkippedURIsAndPromotesOnDecide() async throws {
        let vm = makeViewModel(seed: 13)
        await vm.createBatch(frame: .uniformRandom, size: 4, reader: reader)
        let batchID = try XCTUnwrap(vm.currentBatchID)
        await vm.openBatch(batchID, reader: reader)

        let skippedURI = try XCTUnwrap(vm.currentItem?.uri)
        vm.skip(context: context)
        // Label the rest normally so we have a clean labelled/skipped split.
        while !vm.isSessionComplete {
            vm.record("neutral", note: nil, context: context)
        }

        let vm2 = makeViewModel(seed: 13)
        await vm2.openBatch(batchID, reader: reader, revisitSkipped: true)
        XCTAssertEqual(Set(vm2.sessionItems.map(\.uri)), [skippedURI])
        XCTAssertTrue(vm2.isRevisitingSkips)

        vm2.record("hate", note: nil, context: context)

        let batch = try XCTUnwrap(context.fetch(
            FetchDescriptor<LabelBatch>(predicate: #Predicate<LabelBatch> { $0.id == batchID })).first)
        XCTAssertFalse(batch.skippedURIs.contains(skippedURI), "decided revisit must leave skippedURIs")
        XCTAssertTrue(batch.labelledURIs.contains(skippedURI), "decided revisit must land in labelledURIs")
    }

    /// Skipping again during a revisit session must leave the URI in `skippedURIs`
    /// (idempotent — no duplicate entries).
    func testRevisitSkippedAgainLeavesItSkipped() async throws {
        let vm = makeViewModel(seed: 13)
        await vm.createBatch(frame: .uniformRandom, size: 2, reader: reader)
        let batchID = try XCTUnwrap(vm.currentBatchID)
        await vm.openBatch(batchID, reader: reader)
        let skippedURI = try XCTUnwrap(vm.currentItem?.uri)
        vm.skip(context: context)

        let vm2 = makeViewModel(seed: 13)
        await vm2.openBatch(batchID, reader: reader, revisitSkipped: true)
        XCTAssertEqual(vm2.sessionItems.map(\.uri), [skippedURI])

        vm2.skip(context: context)

        let batch = try XCTUnwrap(context.fetch(
            FetchDescriptor<LabelBatch>(predicate: #Predicate<LabelBatch> { $0.id == batchID })).first)
        XCTAssertEqual(batch.skippedURIs, [skippedURI])
    }

    /// Progress counts must always reconcile: labelled + skipped + remaining ==
    /// drawnURIs.count.
    func testProgressCountsReconcileWithDrawnCount() async throws {
        let vm = makeViewModel(seed: 13)
        await vm.createBatch(frame: .uniformRandom, size: 4, reader: reader)
        let batchID = try XCTUnwrap(vm.currentBatchID)
        await vm.openBatch(batchID, reader: reader)

        vm.record("hate", note: nil, context: context)
        vm.skip(context: context)
        vm.record("neutral", note: nil, context: context)
        // One item left unlabelled/unskipped this session.

        let batch = try XCTUnwrap(context.fetch(
            FetchDescriptor<LabelBatch>(predicate: #Predicate<LabelBatch> { $0.id == batchID })).first)
        let remaining = batch.drawnURIs.count - batch.labelledURIs.count - batch.skippedURIs.count
        XCTAssertEqual(batch.labelledURIs.count + batch.skippedURIs.count + remaining, batch.drawnURIs.count)
        XCTAssertEqual(batch.labelledURIs.count, 2)
        XCTAssertEqual(batch.skippedURIs.count, 1)
        XCTAssertEqual(remaining, 1)
    }

    // MARK: - Second pass / blindness

    func testSecondPassSessionCarriesNoLabelDataAndCoexistsWithoutOverwrite() async throws {
        let vm = makeViewModel(seed: 21)
        await vm.createBatch(frame: .uniformRandom, size: 3, reader: reader)
        let batch1ID = try XCTUnwrap(vm.currentBatchID)
        await vm.openBatch(batch1ID, reader: reader)
        let pass1URIs = Set(vm.sessionItems.map(\.uri))

        vm.record("hate", note: nil, context: context)
        vm.record("neutral", note: nil, context: context)
        vm.record("counter", note: nil, context: context)

        let batch2ID = try vm.createSecondPass(of: batch1ID, context: context)
        let vm2 = makeViewModel(seed: 21)
        await vm2.openBatch(batch2ID, reader: reader)

        // Same URIs as pass 1 (just possibly reordered).
        XCTAssertEqual(Set(vm2.sessionItems.map(\.uri)), pass1URIs)

        // Structural blindness: the session's item type carries no label/class/score
        // field at all — only `AggregateReader.LabellingContext` fields.
        for item in vm2.sessionItems {
            for child in Mirror(reflecting: item).children {
                let name = child.label?.lowercased() ?? ""
                for forbidden in ["score", "label", "class", "sentiment", "model"] {
                    XCTAssertFalse(name.contains(forbidden),
                                   "session item field '\(name)' must not exist — blindness violated")
                }
            }
        }

        // Pass 2 can be labelled independently and must not disturb pass 1's rows.
        vm2.record("counter", note: nil, context: context)
        vm2.record("counter", note: nil, context: context)
        vm2.record("counter", note: nil, context: context)

        let allHuman = try context.fetch(
            FetchDescriptor<Annotation>(predicate: #Predicate<Annotation> { $0.stage == "human" }))
        XCTAssertEqual(allHuman.count, 6)
        XCTAssertEqual(allHuman.filter { $0.batchID == batch1ID }.count, 3)
        XCTAssertEqual(allHuman.filter { $0.batchID == batch2ID }.count, 3)
        // Original pass-1 labels are untouched.
        let pass1Classes = Set(allHuman.filter { $0.batchID == batch1ID }.map(\.speechClass))
        XCTAssertEqual(pass1Classes, ["hate", "neutral", "counter"])
    }

    // MARK: - agreement

    func testAgreementComputesReportFromBothPasses() async throws {
        let vm = makeViewModel(seed: 31)
        await vm.createBatch(frame: .uniformRandom, size: 2, reader: reader)
        let batch1ID = try XCTUnwrap(vm.currentBatchID)
        await vm.openBatch(batch1ID, reader: reader)
        vm.record("hate", note: nil, context: context)
        vm.record("neutral", note: nil, context: context)

        let batch2ID = try vm.createSecondPass(of: batch1ID, context: context)
        let vm2 = makeViewModel(seed: 31)
        await vm2.openBatch(batch2ID, reader: reader)
        // Both pass-2 items get "hate" regardless of presentation order: one agrees
        // with pass 1 (the item originally labelled "hate"), one disagrees (the item
        // originally labelled "neutral") — order-independent by construction.
        vm2.record("hate", note: nil, context: context)
        vm2.record("hate", note: nil, context: context)

        let report = try XCTUnwrap(vm.agreement(batchID: batch1ID, context: context))
        XCTAssertEqual(report.n, 2)
        XCTAssertEqual(report.percentAgreement, 0.5, accuracy: 1e-9)
    }

    func testAgreementReturnsNilWithoutSecondPass() async throws {
        let vm = makeViewModel(seed: 41)
        await vm.createBatch(frame: .uniformRandom, size: 2, reader: reader)
        let batchID = try XCTUnwrap(vm.currentBatchID)
        await vm.openBatch(batchID, reader: reader)
        vm.record("hate", note: nil, context: context)
        vm.record("neutral", note: nil, context: context)

        XCTAssertNil(try vm.agreement(batchID: batchID, context: context))
    }

    // MARK: - record write-path integrity

    /// Forces `context.save()` to throw by handing `record` a `ModelContext` from a
    /// SECOND `ModelContainer` opened against the SAME store file with
    /// `allowsSave: false` (spiked independently: SwiftData's default store does throw
    /// `NSCocoaErrorDomain` 513 "couldn't be saved because you don't have permission"
    /// on such a context's `save()` — this is not silently a no-op). The batch/post
    /// rows are readable through it (same file), only the write is rejected.
    func testSaveFailureLeavesNothingPersistedAndDoesNotAdvance() async throws {
        let vm = makeViewModel(seed: 51)
        await vm.createBatch(frame: .uniformRandom, size: 2, reader: reader)
        let batchID = try XCTUnwrap(vm.currentBatchID)
        await vm.openBatch(batchID, reader: reader)
        XCTAssertEqual(vm.sessionItems.count, 2)

        let readOnlyConfig = ModelConfiguration(schema: BlueXSchema.all, url: storeURL,
                                                 allowsSave: false, cloudKitDatabase: .none)
        let readOnlyContainer = try ModelContainer(for: BlueXSchema.all, configurations: readOnlyConfig)
        let readOnlyContext = ModelContext(readOnlyContainer)

        vm.record("hate", note: "should not persist", context: readOnlyContext)

        let failure = try XCTUnwrap(vm.recordError)
        guard case .saveFailed = failure else {
            return XCTFail("expected .saveFailed, got \(failure)")
        }
        XCTAssertEqual(vm.currentIndex, 0, "must not advance on a failed save")

        let batch = try XCTUnwrap(context.fetch(
            FetchDescriptor<LabelBatch>(predicate: #Predicate<LabelBatch> { $0.id == batchID })).first)
        XCTAssertTrue(batch.labelledURIs.isEmpty, "labelledURIs must not be appended on a failed save")
        XCTAssertNil(batch.completedAt)

        let annotations = try context.fetch(FetchDescriptor<Annotation>())
        XCTAssertTrue(annotations.isEmpty, "no Annotation must survive a failed save")
    }

    /// The `Post` for the current item is deleted between draw and record (e.g. a
    /// rescrape). `record` cannot write against it, but the session must still be able
    /// to move on rather than leaving the annotator stuck on a dead item.
    func testRecordWithDeletedPostSurfacesErrorAndAdvancesPastIt() async throws {
        let vm = makeViewModel(seed: 61)
        await vm.createBatch(frame: .uniformRandom, size: 2, reader: reader)
        let batchID = try XCTUnwrap(vm.currentBatchID)
        await vm.openBatch(batchID, reader: reader)
        let firstURI = try XCTUnwrap(vm.currentItem?.uri)

        let postDescriptor = FetchDescriptor<Post>(predicate: #Predicate<Post> { $0.uri == firstURI })
        let post = try XCTUnwrap(context.fetch(postDescriptor).first)
        context.delete(post)
        try context.save()

        vm.record("hate", note: nil, context: context)

        let failure = try XCTUnwrap(vm.recordError)
        guard case .postNotFound(let uri) = failure else {
            return XCTFail("expected .postNotFound, got \(failure)")
        }
        XCTAssertEqual(uri, firstURI)
        XCTAssertEqual(vm.currentIndex, 1, "advances past the dead item like skip()")

        let annotations = try context.fetch(FetchDescriptor<Annotation>())
        XCTAssertTrue(annotations.isEmpty)

        let batch = try XCTUnwrap(context.fetch(
            FetchDescriptor<LabelBatch>(predicate: #Predicate<LabelBatch> { $0.id == batchID })).first)
        XCTAssertTrue(batch.labelledURIs.isEmpty, "the dead URI is not marked labelled")
    }

    // MARK: - Store-open failure

    func testStoreOpenFailureYieldsFailedStateAndPoolUntouched() async throws {
        struct Boom: Error {}
        let vm = LabellingViewModel(annotatorID: "anna",
                                     containerFactory: { throw Boom() },
                                     clock: Date.init,
                                     seedSource: { 1 })
        await vm.createBatch(frame: .uniformRandom, size: 3, reader: reader)

        guard case .failed = vm.loadState else {
            return XCTFail("expected .failed, got \(vm.loadState)")
        }
        let batches = try context.fetch(FetchDescriptor<LabelBatch>())
        XCTAssertTrue(batches.isEmpty)
    }

    func testOpenBatchStoreFailureYieldsFailed() async throws {
        struct Boom: Error {}
        let vm = LabellingViewModel(annotatorID: "anna",
                                     containerFactory: { throw Boom() },
                                     clock: Date.init,
                                     seedSource: { 1 })
        await vm.openBatch(UUID(), reader: reader)

        guard case .failed = vm.loadState else {
            return XCTFail("expected .failed, got \(vm.loadState)")
        }
        XCTAssertTrue(vm.sessionItems.isEmpty)
    }
}
