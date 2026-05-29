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
        // After 2026-05-29 evening: default is Gemma 3 4B. Apple Foundation Models
        // turned out to refuse hate-content classification under its guardrails
        // (even .permissiveContentTransformations), so we de-defaulted it. Gemma 3
        // 4B is the speed/quality/memory sweet spot on an M4.
        XCTAssertEqual(defaults.first?.modelID, "gemma3:4b")
    }

    func testEnsureModelConfigsMigratesDeprecatedDefaults() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        // Simulate a store with each of the deprecated defaults in turn: the
        // migration must move all of them onto gemma3:4b.
        for staleID in ["qwen2.5:7b", "qwen3.6:27b", "apple-foundation"] {
            // Fresh container per loop iteration to avoid clobbering.
            let perRunContainer = try makeContainer()
            let perRunContext = ModelContext(perRunContainer)
            let stale = ModelConfig(
                name: "stale",
                endpoint: staleID == "apple-foundation" ? "apple-foundation" : "http://localhost:11434",
                modelID: staleID,
                promptTemplate: ModelConfig.defaultPromptTemplate,
                isDefault: true
            )
            perRunContext.insert(stale)
            try perRunContext.save()

            try AccountSeeder.ensureModelConfigs(in: perRunContext)
            let after = try perRunContext.fetch(FetchDescriptor<ModelConfig>())
            let defaults = after.filter { $0.isDefault }
            XCTAssertEqual(defaults.count, 1, "exactly one default after migration from \(staleID)")
            XCTAssertEqual(defaults.first?.modelID, "gemma3:4b", "migration target is gemma3:4b for stale=\(staleID)")
            XCTAssertTrue(after.contains { $0.modelID == staleID && !$0.isDefault },
                          "the previously-default \(staleID) is preserved as a non-default option")
        }
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
