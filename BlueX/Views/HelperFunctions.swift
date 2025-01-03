//
//  HelperFunctions.swift
//  BlueX
//
//  Created by Keyan Ghazi-Zahedi on 03.01.25.
//

import Foundation
import CoreData

func createPreviewContext() -> NSManagedObjectContext {
    let container = NSPersistentContainer(name: "BlueX") // Replace "YourModelName" with your Core Data model name
    container.persistentStoreDescriptions.first!.url = URL(fileURLWithPath: "/dev/null") // In-memory store for previews
    
    container.loadPersistentStores { _, error in
        if let error = error as NSError? {
            fatalError("Unresolved error \(error), \(error.userInfo)")
        }
    }
    
    let context = container.viewContext
    
    // Add a sample Account object for previews
    let account = Account(context: context)
    account.displayName = "Sample Account" // Replace with your Account entity properties
    account.createdAt = Date() // Example of another property
    
    do {
        try context.save()
    } catch {
        print("Failed to save preview context: \(error)")
    }
    
    return context
}
