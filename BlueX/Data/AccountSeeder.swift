// BlueX/Data/AccountSeeder.swift
import Foundation
import SwiftData

struct AccountSeeder {

    struct Seed {
        let did: String
        let handle: String
        let displayName: String
        let groupName: String
    }

    static let seeds: [Seed] = [
        // German Media
        Seed(did: "did:plc:6xofcnvvojjnmggqx43zghwh",  handle: "spiegel.de",           displayName: "DER SPIEGEL",        groupName: "German Media"),
        Seed(did: "did:plc:42pjb4dy3p3ubiekmwpkthen",  handle: "zeit.de",               displayName: "ZEIT",               groupName: "German Media"),
        Seed(did: "did:plc:vk2mooi24pafrjmhpg4ymrv3",  handle: "tagesschau.bsky.social",displayName: "Tagesschau",         groupName: "German Media"),
        // International Media
        Seed(did: "did:plc:eclio37ymobqex2ncko63h4r",  handle: "nytimes.com",           displayName: "The New York Times", groupName: "International Media"),
        Seed(did: "did:plc:vovinwhtulbsx4mwfw26r5ni",  handle: "theguardian.com",       displayName: "The Guardian",       groupName: "International Media"),
        Seed(did: "did:plc:ixvke777actf2fcveqlkdbp5",  handle: "bbcnews.bsky.social",   displayName: "BBC News",           groupName: "International Media"),
    ]

    /// Removes every account/group/post/annotation not in `seeds`, then seeds missing entries.
    /// Safe to call at any time — won't touch accounts already in the seed list.
    static func resetToSeedSet(in context: ModelContext) throws {
        let keepDIDs = Set(seeds.map { $0.did })

        // Delete accounts (and cascade: posts, annotations via deleteRule)
        let allAccounts = try context.fetch(FetchDescriptor<TrackedAccount>())
        for account in allAccounts where !keepDIDs.contains(account.did) {
            context.delete(account)
        }

        // Delete groups that no longer have members
        let allGroups = try context.fetch(FetchDescriptor<AccountGroup>())
        for group in allGroups where group.accounts.isEmpty {
            context.delete(group)
        }

        try context.save()

        // Now seed any missing accounts
        try seed(into: context)
    }

    static func seed(into context: ModelContext) throws {
        let existingAccounts = try context.fetch(FetchDescriptor<TrackedAccount>())
        guard existingAccounts.isEmpty else { return }

        let startAt = ATProtoDate.parse("2024-01-01T00:00:00Z") ?? Date()
        var groups: [String: AccountGroup] = [:]

        for seed in seeds {
            if groups[seed.groupName] == nil {
                let group = AccountGroup(name: seed.groupName)
                context.insert(group)
                groups[seed.groupName] = group
            }

            let account = TrackedAccount(
                did: seed.did,
                handle: seed.handle,
                displayName: seed.displayName,
                startAt: startAt
            )
            if let group = groups[seed.groupName] {
                account.groups.append(group)
            }
            context.insert(account)
        }

        // "All Media" group contains every account
        let allGroup = AccountGroup(name: "All Media")
        context.insert(allGroup)
        let allAccounts = try context.fetch(FetchDescriptor<TrackedAccount>())
        allGroup.accounts = allAccounts

        try context.save()
        try ensureModelConfigs(in: context)
    }

    struct ModelPreset {
        let name: String
        let modelID: String
        let isDefault: Bool
    }

    /// Preset Ollama models we know the dev machine has, ordered by recommended use.
    /// Research (2026-05-29) settled on Qwen 3 32B as the new default: 7B models
    /// systematically over-flag political anger as hate, and the 24-32B band is the
    /// documented sweet spot for nuanced multilingual classification. See
    /// Research/LLM_Hate_Counter_Speech_Classification_from_CC.md in the vault.
    static let modelPresets: [ModelPreset] = [
        ModelPreset(name: "Qwen 3.6 27B (Ollama, recommended)", modelID: "qwen3.6:27b", isDefault: true),
        ModelPreset(name: "Gemma 4 26B (Ollama, second opinion)", modelID: "gemma4:26b", isDefault: false),
        ModelPreset(name: "Qwen 2.5 7B (Ollama, fast baseline)", modelID: "qwen2.5:7b", isDefault: false),
        ModelPreset(name: "Qwen 2.5 3B (Ollama, speed tests)", modelID: "qwen2.5:3b", isDefault: false),
    ]

    /// Idempotently ensure every preset ModelConfig exists, replace any stale "llama3.2"
    /// default, and make sure exactly one config is marked default. User-added configs
    /// (any modelID not in the preset list) are preserved.
    static func ensureModelConfigs(in context: ModelContext) throws {
        let existing = try context.fetch(FetchDescriptor<ModelConfig>())
        let existingIDs = Set(existing.map { $0.modelID })

        // Drop the stale llama3.2 seed if it's still around — that model isn't installed.
        for cfg in existing where cfg.modelID == "llama3.2" {
            context.delete(cfg)
        }

        for preset in modelPresets where !existingIDs.contains(preset.modelID) {
            let cfg = ModelConfig(
                name: preset.name,
                endpoint: "http://localhost:11434",
                modelID: preset.modelID,
                promptTemplate: ModelConfig.defaultPromptTemplate,
                isDefault: false
            )
            context.insert(cfg)
        }
        // Re-sync prompt + display name on any of OUR preset configs to the latest
        // defaults — picks up prompt revisions in code without wiping the user's data.
        // User-added configs (modelIDs outside the preset list) are left alone.
        let presetByID = Dictionary(uniqueKeysWithValues: modelPresets.map { ($0.modelID, $0) })
        let afterInsert = try context.fetch(FetchDescriptor<ModelConfig>())
        for cfg in afterInsert {
            if let preset = presetByID[cfg.modelID] {
                if cfg.promptTemplate != ModelConfig.defaultPromptTemplate {
                    cfg.promptTemplate = ModelConfig.defaultPromptTemplate
                }
                if cfg.name != preset.name {
                    cfg.name = preset.name
                }
            }
        }
        try context.save()

        // Ensure exactly one isDefault, and migrate users off the stale qwen2.5:7b
        // default established by the seeder before 2026-05-29. The current
        // research-backed default is the largest installed Qwen 3.
        let refreshed = try context.fetch(FetchDescriptor<ModelConfig>())
        let preferredDefault = refreshed.first { $0.modelID == "qwen3.6:27b" }
                              ?? refreshed.first

        // (a) If the current default is the deprecated qwen2.5:7b, flip to qwen3.6:27b.
        if let staleDefault = refreshed.first(where: { $0.isDefault && $0.modelID == "qwen2.5:7b" }),
           let newDefault = preferredDefault,
           newDefault.modelID != staleDefault.modelID {
            staleDefault.isDefault = false
            newDefault.isDefault = true
            try context.save()
        }

        // (b) If no config is the default at all (e.g. all imported flat), set one.
        let after = try context.fetch(FetchDescriptor<ModelConfig>())
        if after.first(where: { $0.isDefault }) == nil {
            for cfg in after { cfg.isDefault = false }
            (after.first(where: { $0.modelID == "qwen3.6:27b" }) ?? after.first)?.isDefault = true
            try context.save()
        }
    }
}
