import SwiftUI
import SwiftData

@main
struct BlueXApp: App {

    /// Explicit SwiftData store at ~/Library/Application Support/BlueX/default.store.
    /// BlueX is not sandboxed (research instrument), so the default container path
    /// (~/Library/Application Support/default.store) is shared with every other
    /// non-sandboxed SwiftData app on the machine — at least one of those (a tool
    /// with a `ZAPIREQUESTMODEL` entity) clobbered BlueX's store on 2026-05-28.
    /// Pin to a dedicated subdirectory so no other app can collide.
    let modelContainer: ModelContainer = {
        let storeURL = URL.applicationSupportDirectory
            .appendingPathComponent("BlueX", isDirectory: true)
            .appendingPathComponent("default.store", isDirectory: false)
        try? FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let schema = Schema([
            TrackedAccount.self,
            AccountGroup.self,
            Post.self,
            Annotation.self,
            AccountSnapshot.self,
            ScrapeLog.self,
            ModelConfig.self,
            CoordinatorState.self,
        ])
        let config = ModelConfiguration(schema: schema, url: storeURL)
        do {
            return try ModelContainer(for: schema, configurations: config)
        } catch {
            fatalError("Could not open the BlueX store at \(storeURL.path): \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(modelContainer)
        .commands {
            // Why: CommandGroup(replacing:) removes Xcode's default menu entries
            // we don't need, giving us clean control over the menu bar.
            CommandGroup(replacing: .help) { }
        }
    }
}
