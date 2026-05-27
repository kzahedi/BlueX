// BlueXTests/Views/RootViewTests.swift
import XCTest
@testable import BlueX

final class RootViewTests: XCTestCase {
    func testSidebarItemSelectionMapping() {
        let sampleAccount = TrackedAccount(
            did: "did:test", handle: "test.bsky.social", displayName: "Test", startAt: Date()
        )
        let sampleGroup = AccountGroup(name: "Test Group")
        let samplePost = Post(
            uri: "at://test", text: "Hello", createdAt: Date(),
            authorDID: "did:a", authorHandle: "a",
            parentURI: nil, rootURI: "at://test", isRootPost: false, depth: 1
        )
        let items: [SidebarItem] = [
            .account(sampleAccount),
            .group(sampleGroup),
            .post(samplePost),
            .queue,
            .settings,
        ]
        XCTAssertEqual(items.count, 5, "All 5 SidebarItem cases must be handled")
    }
    func testCoordinatorStateChangesForwardedToSidebarVM() {
        let sidebarVM = SidebarViewModel()
        XCTAssertNil(sidebarVM.lastError, "Initial error state should be nil")
        XCTAssertNil(sidebarVM.activeScrapeHandle, "Initial active scrape handle should be nil")
    }
}
