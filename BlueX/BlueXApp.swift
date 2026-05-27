import SwiftUI
import SwiftData

@main
struct BlueXApp: App {
    // Why: modelContainer(for:) creates the shared SwiftData store and injects it
    // into the SwiftUI environment. All views below can use @Query and
    // @Environment(\.modelContext) to read and write data.
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(for: [
            TrackedAccount.self,
            AccountGroup.self,
            Post.self,
            Annotation.self,
            AccountSnapshot.self,
            ScrapeLog.self,
            ModelConfig.self,
            CoordinatorState.self
        ])
        .commands {
            // Why: CommandGroup(replacing:) removes Xcode's default menu entries
            // we don't need, giving us clean control over the menu bar.
            CommandGroup(replacing: .help) { }
        }
    }
}
