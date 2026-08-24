import XCTest
import SwiftData
@testable import BlueX

/// File-backed container deliberately, not in-memory: in-memory hides migration and
/// storage-representation issues (e.g. the `Int64(bitPattern:)` seed round-trip) that
/// only surface once SQLite is actually involved.
final class LabelBatchTests: XCTestCase {
    var container: ModelContainer!
    var context: ModelContext!
    var storeDir: URL!

    override func setUpWithError() throws {
        storeDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("bluex-labelbatch-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        let storeURL = storeDir.appendingPathComponent("test.store")

        let config = ModelConfiguration(schema: BlueXSchema.all, url: storeURL)
        container = try ModelContainer(for: BlueXSchema.all, configurations: config)
        context = ModelContext(container)
    }

    override func tearDownWithError() throws {
        container = nil
        context = nil
        if let storeDir { try? FileManager.default.removeItem(at: storeDir) }
    }

    func testFrameDecodesBackEqualToOriginal() throws {
        let frame = SamplingFrame(kind: .filtered, outletPK: 42, dateFrom: Date(timeIntervalSince1970: 0),
                                   dateTo: Date(timeIntervalSince1970: 1_000), minThreadReplies: 1,
                                   maxThreadReplies: 10)
        let batch = LabelBatch(frame: frame, poolSizeAtDraw: 500, seed: 12345,
                                drawnURIs: ["at://a", "at://b"], passNumber: 1)
        context.insert(batch)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<LabelBatch>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched[0].frame, frame)
    }

    func testFrameJSONUsesPlainKeyNames() throws {
        let batch = LabelBatch(frame: .uniformRandom, poolSizeAtDraw: 10, seed: 1,
                                drawnURIs: [], passNumber: 1)
        XCTAssertTrue(batch.frameJSON.contains("\"kind\""))
        XCTAssertTrue(batch.frameJSON.contains("\"uniformRandom\""))
    }

    func testSeedSurvivesBitPatternRoundTripIncludingAboveInt64Max() throws {
        let largeSeed = UInt64.max - 3
        let batch = LabelBatch(frame: .uniformRandom, poolSizeAtDraw: 100, seed: largeSeed,
                                drawnURIs: ["at://x"], passNumber: 1)
        context.insert(batch)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<LabelBatch>())
        XCTAssertEqual(fetched[0].seed, largeSeed)
    }

    func testSkippedURIsDefaultsToEmptyAndRoundTrips() throws {
        let batch = LabelBatch(frame: .uniformRandom, poolSizeAtDraw: 4, seed: 7,
                                drawnURIs: ["at://a", "at://b"], passNumber: 1)
        XCTAssertEqual(batch.skippedURIs, [])

        batch.skippedURIs.append("at://a")
        context.insert(batch)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<LabelBatch>())
        XCTAssertEqual(fetched[0].skippedURIs, ["at://a"])
    }

    func testDrawnURIsOrderIsPreserved() throws {
        let uris = ["at://z", "at://a", "at://m", "at://b"]
        let batch = LabelBatch(frame: .uniformRandom, poolSizeAtDraw: 4, seed: 7,
                                drawnURIs: uris, passNumber: 1)
        context.insert(batch)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<LabelBatch>())
        XCTAssertEqual(fetched[0].drawnURIs, uris)
    }

    func testSourceBatchIDLinksPassTwoToPassOne() throws {
        let pass1 = LabelBatch(frame: .uniformRandom, poolSizeAtDraw: 200, seed: 99,
                                drawnURIs: ["at://one"], passNumber: 1)
        context.insert(pass1)
        try context.save()

        let pass2 = LabelBatch(frame: .uniformRandom, poolSizeAtDraw: 200, seed: 100,
                                drawnURIs: ["at://one"], passNumber: 2, sourceBatchID: pass1.id)
        context.insert(pass2)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<LabelBatch>())
        let fetchedPass2 = try XCTUnwrap(fetched.first { $0.passNumber == 2 })
        XCTAssertEqual(fetchedPass2.sourceBatchID, pass1.id)
    }

    func testAnnotationWithoutHumanLabelFieldsReadsBackNil() throws {
        let annotation = Annotation(
            speechClass: "hate", sentimentScore: -0.8, detectedLanguage: "de",
            modelName: "llama3.2", modelVersion: "latest", promptHash: "abc123",
            rawResponse: "{\"class\":\"hate\"}", stage: "llm",
            severity: "moderate", confidence: 0.92
        )
        context.insert(annotation)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Annotation>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertNil(fetched[0].annotatorID)
        XCTAssertNil(fetched[0].batchID)
        XCTAssertNil(fetched[0].timeToDecideSeconds)
        XCTAssertNil(fetched[0].passNumber)
    }
}
