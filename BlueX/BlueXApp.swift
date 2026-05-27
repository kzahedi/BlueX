import SwiftUI
import SwiftData

@main
struct BlueXApp: App {
    var body: some Scene {
        WindowGroup {
            Text("BlueX v2")
        }
        .modelContainer(for: [])
    }
}
