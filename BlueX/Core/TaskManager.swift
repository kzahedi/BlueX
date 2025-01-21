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
    @Published var feedProgress: Double = 0.0 // 0.0 to 1.0
    
    @Published var isReplyScraperRunning = false
    @Published var replyTreeProgress: Double = 0.0 // 0.0 to 1.0
    
    @Published var isCalculatingStatistics = false
    @Published var calcualteStatisticsProgress: Double = 0.0 // 0.0 to 1.0
    
    @Published var isCalculatingSentiments = false
    @Published var calcualtedSentimentsProgress: Double = 0.0 // 0.0 to 1.0
    
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
    
    func runReplyScraper(did:String, name:String, earliestDate:Date, force:Bool) {
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
                try self.replyHandler.runFor(did:did) {progress in
                    DispatchQueue.main.async {
                        self.replyTreeProgress = progress
                    }
                }
                
            } catch {
                print("Error scraping reply trees \(did): \(error)")
            }
        }, completion: {
            // Update task completion state on the main thread
            self.isReplyScraperRunning = false
            notifyTaskCompletion(taskName: "Reply tree scraping", accountName:name)
        })
    }
    
    func runFeedScraper(did:String, name:String, earliestDate:Date, force:Bool) {
        // Prevent starting the task again if it's already running
        guard !isFeedScraperRunning else {
            print("Task is already running.")
            return
        }
        
        // Start background task
        isFeedScraperRunning = true
        print("Starting scraping task for \(did) ...")
        
        DispatchQueue.background(delay:0.0, background: {
            Task {
                await self.feedHandler.runFor(did:did) {progress in
                    DispatchQueue.main.async {
                        self.feedProgress = progress
                    }
                }
            }
        }, completion: {
            self.isFeedScraperRunning = false
            notifyTaskCompletion(taskName: "Feed scraping", accountName: name)
        })
        // Update task completion state on the main thread
    }
    
    func calculateStatistics(did:String, name:String) {
        // Prevent starting the task again if it's already running
      
    }
    
    func calculateSentiments(did:String, name:String) {
    }
}
