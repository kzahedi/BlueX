// BlueXTests/ViewModels/SidebarViewModelTests.swift
import XCTest
@testable import BlueX

final class SidebarViewModelTests: XCTestCase {
    func testInitialStateIsIdle() {
        let vm = SidebarViewModel()
        XCTAssertEqual(vm.scrapePhase, .idle)
        XCTAssertNil(vm.lastError)
        XCTAssertTrue(vm.expandedGroups.isEmpty)
    }
    func testActiveScrapeHandleUpdates() {
        let vm = SidebarViewModel()
        vm.activeScrapeHandle = "spiegel.de"
        XCTAssertEqual(vm.activeScrapeHandle, "spiegel.de")
    }
    func testLastErrorCanBeCleared() {
        let vm = SidebarViewModel()
        vm.lastError = .authFailed
        XCTAssertNotNil(vm.lastError)
        vm.lastError = nil
        XCTAssertNil(vm.lastError)
    }
    func testScrapeProgressClamped() {
        let vm = SidebarViewModel()
        vm.scrapeProgress = 0.75
        XCTAssertEqual(vm.scrapeProgress, 0.75, accuracy: 0.001)
    }
}
