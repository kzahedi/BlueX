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
    @Published var calcualteStatistics: Double = 0.0 // 0.0 to 1.0
    
    private var feedHandler = BlueskyFeedHandler()
    private var replyHandler = BlueskyRepliesHandler()
    private var countReplies = CountReplies()
    
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
        self.countReplies.context = backgroundContext
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
                try self.replyHandler.runFor(did:did,
                                             earliestDate: earliestDate,
                                             forceUpdate: force) {progress in
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
            self.notifyTaskCompletion(taskName: "Reply tree scraping", accountName:name)
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
            do {
                try self.feedHandler.runFor(did:did, earliestDate: earliestDate, forceUpdate: force)
                
            } catch {
                print("Error scraping \(did): \(error)")
            }
        }, completion: {
            self.isFeedScraperRunning = false
            self.notifyTaskCompletion(taskName: "Feed scraping", accountName: name)
        })
        // Update task completion state on the main thread
    }
    
    func calculateStatistics(did:String, name:String) {
        // Prevent starting the task again if it's already running
        guard !isCalculatingStatistics else {
            print("Task is already running.")
            return
        }
        
        // Start background task
        isCalculatingStatistics = true
        print("Calculating statistics for \(did) ...")
        
        DispatchQueue.background(delay:0.0, background: {
            do {
                try self.countReplies.runFor(did:did) {progress in
                    DispatchQueue.main.async {
                        self.calcualteStatistics = progress
                    }
                }
                
            } catch {
                print("Error scraping \(did): \(error)")
            }
        }, completion: {
            self.isCalculatingStatistics = false
            self.notifyTaskCompletion(taskName: "Statistics calculation", accountName: name)
        })
        // Update task completion state on the main thread
    }
    
    func notifyTaskCompletion(taskName: String, accountName: String) {
        sendNotification(
            title: "BlueX",
            subtitle: accountName,
            body: "\(taskName) has successfully finished."
        )
    }
}
