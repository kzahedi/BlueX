import SwiftUI
import SwiftData

@main
struct BlueXApp: App {

    let modelContainer: ModelContainer = {
        do {
            return try BlueXStore.openContainer()
        } catch {
            fatalError("Could not open the BlueX store at \(BlueXStore.url.path): \(error)")
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
