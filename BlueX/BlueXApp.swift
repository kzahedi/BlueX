//
//  BlueXApp.swift
//  BlueX
//
//  Created by Keyan Ghazi-Zahedi on 03.01.25.
//

import SwiftUI
import UserNotifications


@main
struct BlueXApp: App {
    let persistenceController = PersistenceController.shared
    private var notificationDelegate = NotificationDelegate()

    @StateObject private var taskManager = TaskManager()
    
    init() {
        let center = UNUserNotificationCenter.current()
        center.delegate = notificationDelegate
        
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                print("Error requesting notification permission: \(error)")
            } else if granted {
                print("Notification permission granted")
//                sendNotification(title: "BlueX", subtitle: "Hello World!", body: "My first notification")
            } else {
                print("Notification permission denied")
            }
        }
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
                .environmentObject(taskManager)  // Provide TaskManager to all views
        }
        .commands {
            ProcessesMenu()
            LoggerMenu()
        }
        Settings {
            SettingsView()
        }
        
        
    }
}



class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Show the notification as a banner
        completionHandler([.banner, .sound])
    }
}
