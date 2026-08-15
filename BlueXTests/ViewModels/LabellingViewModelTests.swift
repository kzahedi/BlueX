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

    func testSkipAdvancesWithoutRecordingAndLeavesURIUnlabelled() async throws {
        let vm = makeViewModel(seed: 13)
        await vm.createBatch(frame: .uniformRandom, size: 2, reader: reader)
        let batchID = try XCTUnwrap(vm.currentBatchID)
        await vm.openBatch(batchID, reader: reader)
        let firstURI = try XCTUnwrap(vm.currentItem?.uri)

        vm.skip()
        XCTAssertEqual(vm.currentIndex, 1)

        let annotations = try context.fetch(FetchDescriptor<Annotation>())
        XCTAssertTrue(annotations.isEmpty)

        let vm2 = makeViewModel(seed: 13)
        await vm2.openBatch(batchID, reader: reader)
        XCTAssertTrue(vm2.sessionItems.contains { $0.uri == firstURI })
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
