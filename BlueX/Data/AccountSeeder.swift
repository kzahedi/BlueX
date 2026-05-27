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

        // Seed default Ollama model config
        let defaultConfig = ModelConfig(
            name: "Llama 3.2 (Ollama)",
            endpoint: "http://localhost:11434",
            modelID: "llama3.2",
            promptTemplate: ModelConfig.defaultPromptTemplate,
            isDefault: true
        )
        context.insert(defaultConfig)

        try context.save()
    }
}
