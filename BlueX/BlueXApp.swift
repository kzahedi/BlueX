import SwiftUI
import SwiftData

@main
struct BlueXApp: App {

    let modelContainer: ModelContainer = {
        do {
            return try BlueXStore.openContainer()
        } catch {
            // A visible, non-negotiable crash rather than a silent empty session
            // view — an empty UI is exactly how the 2026-08-24 schema-drop bug hid.
            // `error.localizedDescription` (not raw string interpolation) is what
            // actually surfaces `StoreError.errorDescription`, including the
            // schema-version guard's remedy text.
            fatalError("Could not open the BlueX store at \(BlueXStore.url.path): \(error.localizedDescription)")
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
