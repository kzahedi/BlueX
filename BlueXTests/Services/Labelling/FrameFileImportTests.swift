import XCTest
import SwiftData
@testable import BlueX

/// Covers `FrameFileImport`: turning a committee-produced stratified frame file into
/// one `LabelBatch` per stratum. The load-bearing properties are (1) the app never
/// sees a score — any per-URI entry that isn't a bare string is refused outright —
/// and (2) every rejection is all-or-nothing: a bad file creates ZERO batches, never a
/// partial import.
final class FrameFileImportTests: XCTestCase {
    var container: ModelContainer!
    var context: ModelContext!
    var storeDir: URL!

    override func setUpWithError() throws {
        storeDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("bluex-frameimport-tests-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - Fixture builders

    private func writeFrameFile(_ json: [String: Any]) throws -> URL {
        let url = storeDir.appendingPathComponent("frame-\(UUID().uuidString).json")
        let data = try JSONSerialization.data(withJSONObject: json, options: [])
        try data.write(to: url)
        return url
    }

    private func validFrameJSON(strata: [[String: Any]]? = nil) -> [String: Any] {
        [
            "frame_kind": "stratified",
            "created_at": "2026-08-24T10:01:13Z",
            "committee": ["db_sha256": "9de33d1c24b585ffa4c8dd100beac", "members": ["a", "b", "c"]],
            "population_total": 2_197_443,
            "seed": 20260824,
            "strata": strata ?? [
                ["id": "tox_top_1", "definition": "tox_pct >= 99.0000",
                 "population_size": 20844, "uris": ["at://a1", "at://a2"]],
                ["id": "mid", "definition": "25-99 percentile",
                 "population_size": 1_493_812, "uris": ["at://b1", "at://b2", "at://b3"]],
            ],
        ]
    }

    private func fetchBatches() throws -> [LabelBatch] {
        try context.fetch(FetchDescriptor<LabelBatch>())
    }

    // MARK: - Happy path

    func testImportCreatesOneBatchPerStratumWithRightURIsAndFrameFields() throws {
        let url = try writeFrameFile(validFrameJSON())
        let result = try FrameFileImport.importFrameFile(at: url, context: context)

        XCTAssertEqual(result.createdBatchIDs.count, 2)
        let batches = try fetchBatches()
        XCTAssertEqual(batches.count, 2)

        let tox = try XCTUnwrap(batches.first { $0.frame?.stratumID == "tox_top_1" })
        XCTAssertEqual(tox.drawnURIs, ["at://a1", "at://a2"])
        XCTAssertEqual(tox.frame?.kind, .stratified)
        XCTAssertEqual(tox.frame?.stratumDefinition, "tox_pct >= 99.0000")
        XCTAssertEqual(tox.frame?.populationSize, 20844)
        XCTAssertEqual(tox.passNumber, 1)
        XCTAssertNotNil(tox.frame?.frameFileSHA256)
        XCTAssertEqual(tox.frame?.drawSeed, 20260824)

        let mid = try XCTUnwrap(batches.first { $0.frame?.stratumID == "mid" })
        XCTAssertEqual(mid.drawnURIs, ["at://b1", "at://b2", "at://b3"])
        XCTAssertEqual(mid.frame?.populationSize, 1_493_812)
    }

    // MARK: - Rejections — each must create ZERO batches

    func testRejectsMissingPopulationSize() throws {
        let json = validFrameJSON(strata: [
            ["id": "s1", "definition": "d", "uris": ["at://a"]],
        ])
        let url = try writeFrameFile(json)
        XCTAssertThrowsError(try FrameFileImport.importFrameFile(at: url, context: context))
        XCTAssertEqual(try fetchBatches().count, 0)
    }

    func testRejectsZeroPopulationSize() throws {
        let json = validFrameJSON(strata: [
            ["id": "s1", "definition": "d", "population_size": 0, "uris": ["at://a"]],
        ])
        let url = try writeFrameFile(json)
        XCTAssertThrowsError(try FrameFileImport.importFrameFile(at: url, context: context))
        XCTAssertEqual(try fetchBatches().count, 0)
    }

    func testRejectsMissingCommitteeSHA256() throws {
        var json = validFrameJSON()
        json["committee"] = ["members": ["a", "b", "c"]]
        let url = try writeFrameFile(json)
        XCTAssertThrowsError(try FrameFileImport.importFrameFile(at: url, context: context))
        XCTAssertEqual(try fetchBatches().count, 0)
    }

    func testRejectsStratumWithEmptyURIList() throws {
        let json = validFrameJSON(strata: [
            ["id": "s1", "definition": "d", "population_size": 100, "uris": []],
        ])
        let url = try writeFrameFile(json)
        XCTAssertThrowsError(try FrameFileImport.importFrameFile(at: url, context: context))
        XCTAssertEqual(try fetchBatches().count, 0)
    }

    /// The blindness guarantee: a per-URI entry carrying a numeric score field (not a
    /// bare string) must be refused outright, not silently coerced or dropped.
    func testRejectsPerURIObjectCarryingScoreField() throws {
        let json = validFrameJSON(strata: [
            ["id": "s1", "definition": "d", "population_size": 100,
             "uris": [["uri": "at://a", "score": 0.97]]],
        ])
        let url = try writeFrameFile(json)
        XCTAssertThrowsError(try FrameFileImport.importFrameFile(at: url, context: context))
        XCTAssertEqual(try fetchBatches().count, 0)
    }

    func testRejectsDuplicateURIsAcrossStrata() throws {
        let json = validFrameJSON(strata: [
            ["id": "s1", "definition": "d1", "population_size": 100, "uris": ["at://dup", "at://a"]],
            ["id": "s2", "definition": "d2", "population_size": 200, "uris": ["at://dup", "at://b"]],
        ])
        let url = try writeFrameFile(json)
        XCTAssertThrowsError(try FrameFileImport.importFrameFile(at: url, context: context))
        XCTAssertEqual(try fetchBatches().count, 0)
    }

    // MARK: - Idempotent re-import

    func testReimportingSameFileCreatesNoDuplicates() throws {
        let url = try writeFrameFile(validFrameJSON())
        _ = try FrameFileImport.importFrameFile(at: url, context: context)
        XCTAssertEqual(try fetchBatches().count, 2)

        let second = try FrameFileImport.importFrameFile(at: url, context: context)
        XCTAssertEqual(second.createdBatchIDs.count, 0)
        XCTAssertEqual(try fetchBatches().count, 2)
    }

    /// Two DIFFERENT frame files (different content -> different SHA256) must not be
    /// treated as the same import even if a stratum ID happens to repeat.
    func testDifferentFilesWithSameStratumIDAreNotTreatedAsDuplicates() throws {
        let urlA = try writeFrameFile(validFrameJSON())
        _ = try FrameFileImport.importFrameFile(at: urlA, context: context)

        var jsonB = validFrameJSON()
        jsonB["seed"] = 999 // changes file bytes -> different SHA256
        let urlB = try writeFrameFile(jsonB)
        let result = try FrameFileImport.importFrameFile(at: urlB, context: context)

        XCTAssertEqual(result.createdBatchIDs.count, 2)
        XCTAssertEqual(try fetchBatches().count, 4)
    }
}
