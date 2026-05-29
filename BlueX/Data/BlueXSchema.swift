import Foundation
import SwiftData

/// Single source of truth for the BlueX SwiftData schema. Used by the GUI's
/// `BlueXApp` and by both CLIs (`blueX-annotate`, `blueX-scrape`) so a new
/// `@Model` added in one place can't be silently missed by another.
enum BlueXSchema {
    static let all: Schema = Schema([
        TrackedAccount.self,
        AccountGroup.self,
        Post.self,
        Annotation.self,
        AccountSnapshot.self,
        ScrapeLog.self,
        ModelConfig.self,
        CoordinatorState.self,
    ])
}

/// Store location + container builder for every process that opens the BlueX
/// database. Anchored at `~/Library/Application Support/BlueX/default.store`
/// so other non-sandboxed SwiftData apps on the machine can't clobber us.
enum BlueXStore {
    static let url: URL = {
        URL.applicationSupportDirectory
            .appendingPathComponent("BlueX", isDirectory: true)
            .appendingPathComponent("default.store", isDirectory: false)
    }()

    /// Creates the parent directory if needed and returns a configured ModelContainer.
    static func openContainer() throws -> ModelContainer {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let config = ModelConfiguration(
            schema: BlueXSchema.all,
            url: url,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: BlueXSchema.all, configurations: config)
    }
}
