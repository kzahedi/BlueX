//
//  Notifications.swift
//  BlueX
//
//  Created by Keyan Ghazi-Zahedi on 05.01.25.
//

import UserNotifications

func requestNotificationPermission() {
    let center = UNUserNotificationCenter.current()
    center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
        if let error = error {
            print("Error requesting notification permission: \(error)")
        } else {
            print("Notification permission granted: \(granted)")
        }
    }
}

func sendNotification(title: String, subtitle: String, body: String) {
    let content = UNMutableNotificationContent()
    content.title = title
    content.subtitle = subtitle
    content.body = body
    content.sound = .default
    
    // Create a trigger to fire the notification immediately
    let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
    
    // Create a unique identifier for this notification
    let identifier = UUID().uuidString
    let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
    
    // Add the notification request to the notification center
    let center = UNUserNotificationCenter.current()
    center.add(request) { error in
        if let error = error {
            print("Error scheduling notification: \(error)")
        }
    }
}
