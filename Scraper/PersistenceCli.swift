//
//  Persistence.swift
//  BlueX
//
//  Created by Keyan Ghazi-Zahedi on 03.01.25.
//

import CoreData

struct CliPersistenceController {
    static let shared = CliPersistenceController()
    
    @MainActor
    static let preview: CliPersistenceController = {
        let result = CliPersistenceController(inMemory: true)
        let viewContext = result.container.viewContext
        for _ in 0..<10 {
            let newAccount = Account(context: viewContext)
            newAccount.id = UUID()
        }
        do {
            try viewContext.save()
        } catch {
            // Handle the error appropriately
            let nsError = error as NSError
            fatalError("Unresolved error \(nsError), \(nsError.userInfo)")
        }
        return result
    }()
    
    func getSharedSQLiteURL() -> URL {
//        var sharedDirectoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
//        sharedDirectoryURL = sharedDirectoryURL.appendingPathComponent("BlueX")
//        return sharedDirectoryURL.appendingPathComponent("BlueX.sqlite")
        return URL(fileURLWithPath: "/Users/zahedi/Library/Containers/kgz.BlueX/Data/Documents/BlueX/BlueX.sqlite")
    }
    
    let container: NSPersistentContainer
    
    init(inMemory: Bool = false) {
        container = NSPersistentContainer(name: "BlueX") // Replace with your actual model name
        
        if inMemory {
            // If inMemory is true, use an in-memory store
            container.persistentStoreDescriptions.first!.url = URL(fileURLWithPath: "/dev/null")
        } else {
           // Use the App Group for shared SQLite store
            let storeURL = getSharedSQLiteURL()
            print("Using shared SQLite store at \(storeURL)")
            
            // Set the URL for the persistent store
            container.persistentStoreDescriptions.first!.url = storeURL
        }
        
        // Load the persistent store
        container.loadPersistentStores { storeDescription, error in
            if let error = error as NSError? {
                // Handle the error appropriately
                fatalError("Unresolved error \(error), \(error.userInfo)")
            } else {
                print("Persistent store loaded successfully: \(storeDescription)")
            }
        }
        
        // Enable automatic merging of changes from parent context
        container.viewContext.automaticallyMergesChangesFromParent = true
        
        // Enable automatic history tracking for cache cleanups
        container.persistentStoreDescriptions.forEach { description in
            description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        }
    }
}
