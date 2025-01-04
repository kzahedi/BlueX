//
//  BlueXApp.swift
//  BlueX
//
//  Created by Keyan Ghazi-Zahedi on 03.01.25.
//

import SwiftUI

@main
struct BlueXApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
        Settings {
            SettingsView()
        }
    }
}
