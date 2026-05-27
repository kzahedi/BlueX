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
        Seed(did: "did:plc:6xofcnvvojjnmggqx43zghwh", handle: "spiegel.de",        displayName: "DER SPIEGEL",         groupName: "German Media"),
        Seed(did: "did:plc:42pjb4dy3p3ubiekmwpkthen", handle: "zeit.de",            displayName: "ZEIT",                groupName: "German Media"),
        Seed(did: "",                                  handle: "sueddeutsche.de",    displayName: "Süddeutsche Zeitung", groupName: "German Media"),
        Seed(did: "",                                  handle: "faz.net",            displayName: "FAZ",                 groupName: "German Media"),
        Seed(did: "",                                  handle: "taz.social",         displayName: "taz",                 groupName: "German Media"),
        Seed(did: "",                                  handle: "tagesspiegel.de",    displayName: "Tagesspiegel",        groupName: "German Media"),
        Seed(did: "",                                  handle: "welt.de",            displayName: "Die Welt",            groupName: "German Media"),
        Seed(did: "",                                  handle: "stern.de",           displayName: "Stern",               groupName: "German Media"),
        Seed(did: "",                                  handle: "dw.com",             displayName: "Deutsche Welle",      groupName: "German Media"),
        Seed(did: "",                                  handle: "tagesschau.de",      displayName: "Tagesschau",          groupName: "German Media"),
        Seed(did: "",                                  handle: "zdf.de",             displayName: "ZDF",                 groupName: "German Media"),
        // US Media
        Seed(did: "did:plc:eclio37ymobqex2ncko63h4r", handle: "nytimes.com",        displayName: "The New York Times",  groupName: "US Media"),
        Seed(did: "",                                  handle: "washingtonpost.com", displayName: "The Washington Post", groupName: "US Media"),
        Seed(did: "",                                  handle: "theguardian.com",    displayName: "The Guardian",        groupName: "US Media"),
        Seed(did: "",                                  handle: "npr.org",            displayName: "NPR",                 groupName: "US Media"),
        Seed(did: "",                                  handle: "cnn.com",            displayName: "CNN",                 groupName: "US Media"),
        Seed(did: "",                                  handle: "theatlantic.com",    displayName: "The Atlantic",        groupName: "US Media"),
        Seed(did: "",                                  handle: "politico.com",       displayName: "Politico",            groupName: "US Media"),
        Seed(did: "",                                  handle: "reuters.com",        displayName: "Reuters",             groupName: "US Media"),
        Seed(did: "",                                  handle: "apnews.com",         displayName: "Associated Press",    groupName: "US Media"),
        Seed(did: "",                                  handle: "propublica.org",     displayName: "ProPublica",          groupName: "US Media"),
    ]

    static func seed(into context: ModelContext) throws {
        let existingAccounts = try context.fetch(FetchDescriptor<TrackedAccount>())
        guard existingAccounts.isEmpty else { return }

        let startAt = ISO8601DateFormatter().date(from: "2024-01-01T00:00:00Z") ?? Date()
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
