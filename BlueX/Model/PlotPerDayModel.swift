//
//  AccountViewModel.swift
//  BlueX
//
//  Created by Keyan Ghazi-Zahedi on 07.01.25.
//

import Foundation
import SwiftUI
import CoreData

struct PostStatsDataPoint : Codable, Identifiable {
    var id : UUID = UUID()
    var day: Date
    var count: Int
}

class PlotPerDayModel: ObservableObject {
    @Published var displayName: String
    @Published var handle: String
    @Published var did: String
    @Published var timestampFeed: String
    @Published var dataPoints: [PostStatsDataPoint]
    @Published var xMin: Date
    @Published var xMax: Date
    
    let account: Account
    let context: NSManagedObjectContext

    init(account: Account, context: NSManagedObjectContext? = nil) {
        self.account = account
        self.context = context ?? PersistenceController.shared.container.viewContext
        
       
        // Initialize ViewModel properties from CoreData model
        self.displayName = account.displayName ?? ""
        self.handle = account.handle ?? ""
        self.did = account.did ?? ""
        self.timestampFeed = ""
        self.dataPoints = []
        self.xMin = account.startAt ?? Date()
        self.xMax = Date()

        self.updateDataPoints()
    }
    
    func updateDataPoints() {
        let fetchRequest: NSFetchRequest<Post> = Post.fetchRequest()
        fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "accountID == %@", account.id! as CVarArg),
            NSPredicate(format: "rootID == nil"),
            NSPredicate(format: "createdAt >= %@", account.startAt! as NSDate)
        ])
        
        do {
            let posts = try context.fetch(fetchRequest)
            
            // Use Calendar to group posts by day (ignoring time of day)
            let groupedByDay : [Date:[Post]] = Dictionary(grouping: posts) { post in
                guard let timestamp = post.createdAt else {
                    return Date.distantPast // Fallback for invalid timestamps
                }
                return Calendar.current.startOfDay(for: timestamp)
            }
            
            
            // Map to PostStatsDataPoint
            self.dataPoints = groupedByDay.map { (day, posts) in
                PostStatsDataPoint(day: day, count: posts.count)
            }.sorted { $0.day < $1.day } // Sort by day
            
            let today = Calendar.current.startOfDay(for: Date())
            xMax = self.dataPoints.last!.day < today ? today : self.dataPoints.last!.day
            xMin = self.account.startAt == nil ?  self.dataPoints.first!.day : self.account.startAt!
            
        } catch {
            print("Error fetching posts: \(error)")
            self.dataPoints = []
        }
    }
}
