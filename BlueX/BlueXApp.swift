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
    
    @StateObject private var taskManager = TaskManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
                .environmentObject(taskManager)  // Provide TaskManager to all views
        }
        Settings {
            SettingsView()
        }
    }
}
