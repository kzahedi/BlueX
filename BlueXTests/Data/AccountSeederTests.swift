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
        // After the 2026-05-29 evening change, default is Apple Foundation Models —
        // smaller, faster, free, doesn't blow up the M4's unified memory like the
        // 27B Ollama presets did.
        XCTAssertEqual(defaults.first?.modelID, "apple-foundation")
        XCTAssertEqual(defaults.first?.endpoint, "apple-foundation",
                       "Apple Foundation Models uses the sentinel endpoint so ModelClientFactory picks the right transport")
    }

    func testEnsureModelConfigsMigratesDeprecatedDefaults() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        // Simulate a store that was last touched by the previous seeder version,
        // where qwen3.6:27b was the default. The migration must move the default
        // off it onto Apple Foundation Models.
        let stale = ModelConfig(
            name: "Qwen 3.6 27B",
            endpoint: "http://localhost:11434",
            modelID: "qwen3.6:27b",
            promptTemplate: ModelConfig.defaultPromptTemplate,
            isDefault: true
        )
        context.insert(stale)
        try context.save()

        try AccountSeeder.ensureModelConfigs(in: context)
        let after = try context.fetch(FetchDescriptor<ModelConfig>())
        let defaults = after.filter { $0.isDefault }
        XCTAssertEqual(defaults.count, 1)
        XCTAssertEqual(defaults.first?.modelID, "apple-foundation")
        XCTAssertTrue(after.contains { $0.modelID == "qwen3.6:27b" && !$0.isDefault },
                      "the previously-default qwen3.6:27b is preserved as a non-default option")
    }

    func testEnsureModelConfigsSeedsAllNewPresets() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        try AccountSeeder.seed(into: context)
        let configs = try context.fetch(FetchDescriptor<ModelConfig>())
        let modelIDs = Set(configs.map(\.modelID))
        // Four new presets added 2026-05-29 evening: Apple plus three smaller Ollama
        // options that fit in <12 GB unified memory.
        XCTAssertTrue(modelIDs.contains("apple-foundation"))
        XCTAssertTrue(modelIDs.contains("qwen3:8b"))
        XCTAssertTrue(modelIDs.contains("gemma3:4b"))
        XCTAssertTrue(modelIDs.contains("phi4:14b"))
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
