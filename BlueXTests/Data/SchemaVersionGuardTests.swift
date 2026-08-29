// BlueXTests/Data/SchemaVersionGuardTests.swift
import XCTest
import SwiftData
@testable import BlueX

/// Covers the schema-version guard in `BlueXStore.openContainer()`.
///
/// Context: five binaries (the app, `blueX-scrape`, `blueX-authors`,
/// `blueX-annotate`, plus the test host) open the same SwiftData store. A binary
/// built before a model change lightweight-migrates the store DOWN to its own
/// (older) schema, silently destroying newer columns — measured to happen
/// repeatedly on 2026-08-24/25. The guard refuses to open a store whose sidecar
/// version marker is newer than this binary's `BlueXSchema.version`, BEFORE the
/// `ModelContainer` (and therefore any migration) is ever constructed.
final class SchemaVersionGuardTests: XCTestCase {

    private var savedOverride: String?
    private var tempParent: URL!

    override func setUp() {
        super.setUp()
        savedOverride = ProcessInfo.processInfo.environment["BLUEX_STORE_DIR"]
        tempParent = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("bluex-schema-guard-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempParent, withIntermediateDirectories: true)
        setenv("BLUEX_STORE_DIR", tempParent.appendingPathComponent("bluex-data").path, 1)
    }

    override func tearDown() {
        if let savedOverride {
            setenv("BLUEX_STORE_DIR", savedOverride, 1)
        } else {
            unsetenv("BLUEX_STORE_DIR")
        }
        try? FileManager.default.removeItem(at: tempParent)
        super.tearDown()
    }

    private var sidecarURL: URL {
        URL(fileURLWithPath: BlueXStore.url.path + ".schema-version")
    }

    private func readSidecarJSON() -> [String: Any]? {
        guard let data = try? Data(contentsOf: sidecarURL) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: - Absent sidecar

    func testAbsentSidecarOpensAndWritesMarker() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecarURL.path))
        _ = try BlueXStore.openContainer()

        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecarURL.path))
        let marker = try XCTUnwrap(readSidecarJSON())
        XCTAssertEqual(marker["version"] as? Int, BlueXSchema.version)
        XCTAssertEqual(marker["writtenBy"] as? String, ProcessInfo.processInfo.processName)
        XCTAssertNotNil(marker["writtenAt"] as? String)
    }

    // MARK: - Equal version

    func testEqualVersionOpensAndLeavesSidecarUnchanged() throws {
        _ = try BlueXStore.openContainer()
        let before = try Data(contentsOf: sidecarURL)
        let beforeMTime = try FileManager.default.attributesOfItem(atPath: sidecarURL.path)[.modificationDate] as? Date

        // Re-open: version is already equal, so the sidecar must not be rewritten.
        _ = try BlueXStore.openContainer()

        let after = try Data(contentsOf: sidecarURL)
        let afterMTime = try FileManager.default.attributesOfItem(atPath: sidecarURL.path)[.modificationDate] as? Date
        XCTAssertEqual(before, after)
        XCTAssertEqual(beforeMTime, afterMTime)
    }

    // MARK: - Store version lower than binary

    func testLowerStoreVersionOpensAndUpdatesSidecarUpward() throws {
        // Establish a real store, then roll the sidecar back to simulate an older write.
        _ = try BlueXStore.openContainer()
        try writeSidecar(version: 0, writtenBy: "some-old-binary")

        _ = try BlueXStore.openContainer()

        let marker = try XCTUnwrap(readSidecarJSON())
        XCTAssertEqual(marker["version"] as? Int, BlueXSchema.version)
    }

    // MARK: - Store version higher than binary — the test that matters

    func testHigherStoreVersionRefusesAndLeavesStoreUntouched() throws {
        // Establish a real store at the current (lower) version.
        _ = try BlueXStore.openContainer()
        let storeDataBefore = try Data(contentsOf: BlueXStore.url)

        try writeSidecar(version: 9999, writtenBy: "future-binary")
        let sidecarBefore = try Data(contentsOf: sidecarURL)

        XCTAssertThrowsError(try BlueXStore.openContainer()) { error in
            guard case BlueXStore.StoreError.storeWrittenByNewerSchema(let binary, let binaryVersion, let storeVersion) = error else {
                return XCTFail("expected storeWrittenByNewerSchema, got \(error)")
            }
            XCTAssertEqual(binary, ProcessInfo.processInfo.processName)
            XCTAssertEqual(binaryVersion, BlueXSchema.version)
            XCTAssertEqual(storeVersion, 9999)

            let message = (error as? LocalizedError)?.errorDescription ?? ""
            XCTAssertTrue(message.contains(binary))
            XCTAssertTrue(message.contains("9999"))
            XCTAssertTrue(message.contains("\(BlueXSchema.version)"))
            XCTAssertTrue(message.contains(
                "rebuild every binary that opens this store — run tools/install-cli.sh and rebuild the app"))
        }

        // Neither the store file nor the sidecar may have been touched.
        let storeDataAfter = try Data(contentsOf: BlueXStore.url)
        let sidecarAfter = try Data(contentsOf: sidecarURL)
        XCTAssertEqual(storeDataBefore, storeDataAfter, "the store file must be untouched by a refused open")
        XCTAssertEqual(sidecarBefore, sidecarAfter, "the sidecar must be untouched by a refused open")
    }

    // MARK: - Malformed sidecar fails closed

    func testMalformedSidecarRefusesRatherThanTreatingAsAbsent() throws {
        _ = try BlueXStore.openContainer()
        let storeDataBefore = try Data(contentsOf: BlueXStore.url)

        try Data("not valid json {{{".utf8).write(to: sidecarURL, options: .atomic)

        XCTAssertThrowsError(try BlueXStore.openContainer()) { error in
            guard case BlueXStore.StoreError.malformedSchemaVersionMarker = error else {
                return XCTFail("expected malformedSchemaVersionMarker, got \(error)")
            }
        }

        let storeDataAfter = try Data(contentsOf: BlueXStore.url)
        XCTAssertEqual(storeDataBefore, storeDataAfter, "the store file must be untouched by a refused open")
    }

    // MARK: - Drift fingerprint

    /// The fingerprint of the persisted surface (entity names + persisted property
    /// names) BlueXSchema.version == 1 was declared for. If this test fails, a
    /// model gained/lost/renamed a persisted property (or an entity was
    /// added/removed) without a matching bump — bump `BlueXSchema.version` AND
    /// update `expectedFingerprint` below, together, in the same commit.
    private let expectedFingerprint = "7a5fe57a506192ec72cad45da9b92304e7c6997342ea8e31a47c45bebdb39679"

    func testPersistedSurfaceFingerprintMatchesDeclaredVersion() {
        let actual = BlueXSchema.persistedSurfaceFingerprint()
        XCTAssertEqual(actual, expectedFingerprint, """
            The persisted surface of BlueXSchema.all changed (an @Model gained, lost, \
            or renamed a persisted property, or an entity was added/removed) without \
            bumping BlueXSchema.version. Bump BlueXSchema.version AND update \
            `expectedFingerprint` in this test, together, in the same commit. \
            Got: \(actual)
            """)
    }

    // MARK: - Helpers

    private func writeSidecar(version: Int, writtenBy: String) throws {
        let json: [String: Any] = [
            "version": version,
            "writtenBy": writtenBy,
            "writtenAt": ISO8601DateFormatter().string(from: Date()),
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        try data.write(to: sidecarURL, options: .atomic)
    }
}
