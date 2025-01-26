//
//  Statistics.swift
//  Bluesent
//
//  Created by Keyan Ghazi-Zahedi on 23.01.25.
//

import Foundation
import NaturalLanguage
import CoreData
import Progress

struct CalculatePlotData {
    
    let context = CliPersistenceController.shared.container.viewContext
    let accountHandler : AccountHandler = AccountHandler.shared
    let predicatFormat = "account == %@ AND rootURI == nil AND statistics != nil"

    func calculatePlotDataForAllActiveAccounts(batchSize:Int = 100) {
        for account in accountHandler.accounts {
            if account.isActive == false { continue }
            print(account)
            calculateFor(account:account)
        }
    }
    
    func calculateFor(account: Account) {
        removeAllPlotData(account:account)
        print("Calculating plot data for \(account.displayName!)")
        let fetchRequest: NSFetchRequest<Post> = Post.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: predicatFormat, account)
        let count = try! context.count(for: fetchRequest)
        var bar = ProgressBar(count: count)
        bar.setValue(0)
        
        var repliesToPost : [String:[Int64]] = [:] // how many replies to a specific post
        var repliesPerDay : [String:[Int64]] = [:] // how many replies, depending on the day of reply

        
        let calendar = Calendar.current
        var currentDate = Date()
        while currentDate >= account.startAt! {
            currentDate = currentDate.toNoon()
            if let nextDate = calendar.date(byAdding: .day, value: -1, to: currentDate) {
                currentDate = nextDate
            }
            let (day, month, year) = currentDate.dayMonthYear()
            let dateStr = createDateString(day: day, month: month, year: year)!
            
            let posts = getAllRepliesToPostOn(day:day, month:month, year:year, account:account)
            if posts.count == 0 {
                repliesToPost[dateStr] = []
            } else {
                repliesToPost[dateStr] = posts.map{$0.statistics?.totalNumberOfReplies ?? 0}
            }
//            print(repliesToPost[dateStr]!)

        }
 
//        try? context.save()
        print("Completed the calculation of plot data.")
    }
    
    private func recursiveCountRepliesFor(post:Post) -> Int64 {
        var n = post.statistics?.nrOfReplies ?? 0
        if let replies = post.replies as? Set<Post> {
            for reply in replies {
                n += reply.statistics?.nrOfReplies ?? 0
            }
        }
        return n
    }
    
    private func getAllRepliesToPostOn(day:Int, month:Int, year:Int, account:Account) -> [Post] {
        let predicate = NSPredicate(format:"account == %@ AND day == %@ AND month == %@ AND year == %@",
                                    account,
                                    NSNumber(value:day),
                                    NSNumber(value:month),
                                    NSNumber(value:year))
        let fetchRequest: NSFetchRequest<Post> = Post.fetchRequest()
        fetchRequest.predicate = predicate

        if let posts = try? context.fetch(fetchRequest) {
            return posts
        }
        return []
    }
    
    private func removeAllPlotData(account:Account) {
        print("Removing all plot data for \(account.displayName!)")
        if let list = account.plotData as? Set<PlotData> {
            for plotData in list {
                context.delete(plotData)
            }
        }
        account.plotData = nil
        try? context.save()
        print("Done with cleaning up old plot data.")
        
    }
    
   
    
    private func countRepliesForNode(uri:String) throws -> Int64 {
        let fetchRequest: NSFetchRequest<Post> = Post.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "parentURI == %@", uri as CVarArg)
        let posts = try self.context.fetch(fetchRequest)
        return Int64(posts.count)
    }
    
    private func countReplyTreeDepth(post:Post) -> Int64 {
        
        if let repliesSet = post.replies as? Set<Post> {
            let replies = Array(repliesSet)
            
            var maxDepth:Int64 = -1
            for post in replies {
                let d = countReplyTreeDepth(post: post)
                if post.statistics == nil {
                    let stats = Statistics(context: self.context)
                    post.statistics = stats
                    stats.post = post
                }
                post.statistics!.replyTreeDepth = d
                if d > maxDepth { maxDepth = d }
            }
            return maxDepth + 1
        }
        return -1
    }

    private func collectSentiments(post:Post) -> [Double] {
        var values : [Double] = []
        if let replies = post.replies as? Set<Post> {
            values = replies.map{getSentimentScore(post: $0, tool: .NLTagger)}
            for reply in replies {
                values += collectSentiments(post: reply)
            }
        }
        return values
    }
}

