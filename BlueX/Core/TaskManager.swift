//
//  TaskManager.swift
//  BlueX
//
//  Created by Keyan Ghazi-Zahedi on 04.01.25.
//

import Foundation
import SwiftUI
import CoreData

@MainActor  // Ensures updates are made on the main thread
class TaskManager: ObservableObject {
    @Published var isFeedScraperRunning = false
    @Published var isReplyScraperRunning = false

    private var feedHandler = BlueskyFeedHandler()
    private var replyHandler = BlueskyRepliesHandler()
    private var context : NSManagedObjectContext? = nil
    
    init() {
        self.context = PersistenceController.shared.container.viewContext
        self.feedHandler.context = context
        self.replyHandler.context = context
    }
    
    func runReplyScraper(did:String, earliestDate:Date, force:Bool) {
        // Prevent starting the task again if it's already running
        guard !isReplyScraperRunning else {
            print("Task is already running.")
            return
        }
        
        // Start background task
        isReplyScraperRunning = true
        print("Starting scraping reply trees task for \(did) ...")
        
        // Use Task to handle async code
        Task {
            // Simulate long-running task
            
            do {
                try replyHandler.runFor(did:did, earliestDate: earliestDate, forceUpdate: force)
            } catch {
                print("Error scraping reply trees \(did): \(error)")
            }
            
            // Update task completion state on the main thread
            self.isReplyScraperRunning = false
            print("Task completed.")
        }
    }
    
    func runFeedScraper(did:String, earliestDate:Date, force:Bool) {
        // Prevent starting the task again if it's already running
        guard !isFeedScraperRunning else {
            print("Task is already running.")
            return
        }
        
        // Start background task
        isFeedScraperRunning = true
        print("Starting scraping task for \(did) ...")
        
        // Use Task to handle async code
        Task {
            // Simulate long-running task
            
            do {
                try feedHandler.runFor(did:did, earliestDate: earliestDate, forceUpdate: force)
            } catch {
                print("Error scraping \(did): \(error)")
            }
            
            // Update task completion state on the main thread
            self.isFeedScraperRunning = false
            print("Task completed.")
        }
    }
}
