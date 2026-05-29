// BlueXTests/Data/AccountSeederTests.swift
import XCTest
import SwiftData
@testable import BlueX

final class AccountSeederTests: XCTestCase {

    func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: TrackedAccount.self, AccountGroup.self, ModelConfig.self,
            configurations: config
        )
    }

    func testSeedCreatesOneAccountPerSeed() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        try AccountSeeder.seed(into: context)
        let accounts = try context.fetch(FetchDescriptor<TrackedAccount>())
        XCTAssertEqual(accounts.count, AccountSeeder.seeds.count)
    }

    func testSeedIsIdempotent() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        try AccountSeeder.seed(into: context)
        try AccountSeeder.seed(into: context)  // second call should be a no-op
        let accounts = try context.fetch(FetchDescriptor<TrackedAccount>())
        XCTAssertEqual(accounts.count, AccountSeeder.seeds.count)
    }

    func testSeedCreatesExpectedGroups() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        try AccountSeeder.seed(into: context)
        let groups = try context.fetch(FetchDescriptor<AccountGroup>())
        let groupNames = Set(groups.map { $0.name })
        XCTAssertTrue(groupNames.contains("German Media"))
        XCTAssertTrue(groupNames.contains("International Media"))
        XCTAssertTrue(groupNames.contains("All Media"))
    }

    func testSeedCreatesModelConfigsWithDefault() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        try AccountSeeder.seed(into: context)
        let configs = try context.fetch(FetchDescriptor<ModelConfig>())
        XCTAssertEqual(configs.count, AccountSeeder.modelPresets.count)
        let defaults = configs.filter { $0.isDefault }
        XCTAssertEqual(defaults.count, 1, "exactly one ModelConfig should be marked default")
        XCTAssertEqual(defaults.first?.modelID, "qwen3.6:27b")
    }

    func testSpiegelHasKnownDID() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        try AccountSeeder.seed(into: context)
        let accounts = try context.fetch(FetchDescriptor<TrackedAccount>())
        let spiegel = accounts.first { $0.handle == "spiegel.de" }
        XCTAssertNotNil(spiegel)
        XCTAssertEqual(spiegel?.did, "did:plc:6xofcnvvojjnmggqx43zghwh")
    }
}
