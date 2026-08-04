// BlueXTests/Data/BlueXStoreTests.swift
import XCTest
@testable import BlueX

final class BlueXStoreTests: XCTestCase {

    private var savedOverride: String?

    override func setUp() {
        super.setUp()
        savedOverride = ProcessInfo.processInfo.environment["BLUEX_STORE_DIR"]
    }

    override func tearDown() {
        if let savedOverride {
            setenv("BLUEX_STORE_DIR", savedOverride, 1)
        } else {
            unsetenv("BLUEX_STORE_DIR")
        }
        super.tearDown()
    }

    // Pins the constant. The whole point of the change is that the data lives on the
    // external volume, so a silent revert to the internal disk must fail the suite.
    func testDefaultDirectoryIsOnTheEregionVolume() {
        unsetenv("BLUEX_STORE_DIR")
        XCTAssertEqual(BlueXStore.directory.path, "/Volumes/Eregion/bluex-data")
        XCTAssertEqual(BlueXStore.url.lastPathComponent, "default.store")
    }

    func testDirectoryHonoursEnvironmentOverride() {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("bluex-store-override", isDirectory: true)
        setenv("BLUEX_STORE_DIR", tmp.path, 1)
        XCTAssertEqual(BlueXStore.directory.path, tmp.path)
    }

    // The critical guard. With the drive detached, creating the directory would
    // produce a SECOND, empty store — which looks like success and silently
    // orphans 797k posts.
    func testOpenContainerThrowsWhenTheVolumeIsMissing() {
        let missing = "/Volumes/NotMounted-\(UUID().uuidString)/bluex-data"
        setenv("BLUEX_STORE_DIR", missing, 1)

        XCTAssertFalse(BlueXStore.isAvailable)
        XCTAssertThrowsError(try BlueXStore.openContainer()) { error in
            guard case BlueXStore.StoreError.volumeNotMounted = error else {
                return XCTFail("expected volumeNotMounted, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing),
                       "must not create the store directory when the volume is absent")
    }

    func testOpenContainerSucceedsWhenTheParentExists() throws {
        let parent = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("bluex-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        setenv("BLUEX_STORE_DIR", parent.appendingPathComponent("bluex-data").path, 1)
        XCTAssertTrue(BlueXStore.isAvailable)
        _ = try BlueXStore.openContainer()
        XCTAssertTrue(FileManager.default.fileExists(atPath: BlueXStore.url.path))
    }
}
