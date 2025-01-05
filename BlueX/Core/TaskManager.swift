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
        let backgroundContext: NSManagedObjectContext = {
            let context = PersistenceController.shared.container.newBackgroundContext()
            context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
            return context
        }()
        self.feedHandler.context = backgroundContext
        self.replyHandler.context = backgroundContext
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
        
        DispatchQueue.background(delay:0.0, background: {
            do {
                try self.replyHandler.runFor(did:did, earliestDate: earliestDate, forceUpdate: force)
            } catch {
                print("Error scraping reply trees \(did): \(error)")
            }
        }, completion: {
            // Update task completion state on the main thread
            self.isReplyScraperRunning = false
            print("Task completed.")
        })
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
        
        DispatchQueue.background(delay:0.0, background: {
            do {
                try self.feedHandler.runFor(did:did, earliestDate: earliestDate, forceUpdate: force)
            } catch {
                print("Error scraping \(did): \(error)")
            }
        }, completion: {
            self.isFeedScraperRunning = false
            print("Task completed.")
        })
        // Update task completion state on the main thread
    }
}
