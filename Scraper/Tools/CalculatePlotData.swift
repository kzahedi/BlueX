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
    
    private func getDates(account:Account) -> [Date] {
        var dates : [Date] = []
        let today = Date()
        let startAt = account.startAt ?? today
        let calendar = Calendar.current

        var currentDate = Date()
        while currentDate >= startAt {
            dates.append(currentDate.toNoon())
            currentDate = calendar.date(byAdding: .day, value: -1, to: currentDate)!
        }
        dates.sort(by: >)
        return dates
    }
    
    func calculateFor(account: Account) {
        removeAllPlotData(account:account)
        print("Calculating plot data for \(account.displayName!)")
        
        var dates = getDates(account: account)
        let count = dates.count
        var bar = ProgressBar(count: dates.count)
        bar.setValue(0)
        
        
        while !dates.isEmpty {
            bar.setValue(min(count, count - dates.count + 1))
            let date = dates.removeFirst()
            let (day, month, year) = date.dayMonthYear()
 
            let repliesToPost = getAllRepliesToPostOn(day:day, month:month, year:year, account:account)
            let repliesPerDay = Double(getAllRepliesByDate(day:day, month:month, year:year, account:account))
            let postPerDay = Double(getNumberOfPosts(day:day, month:month, year:year, account:account))
            let postSentiments = getAllSentimentsToPostOn(day:day, month:month, year:year, account:account)
            //            let replySentimentsPerPost = []
//            let replySentimentsPerDay = []
            
            var (sum, max, mean, stdDev) = calculateStatistics(values: repliesToPost)
            addPlotData(account: account, day: day, month: month, year: year,
                        sum: sum, mean: mean, stdDev: stdDev, max: max,
                        type: .RepliesPerPost)
           
            addPlotData(account: account, day: day, month: month, year: year,
                        sum: repliesPerDay,
                        type: .RepliesPerDay)
            
            addPlotData(account: account, day: day, month: month, year: year,
                        sum: postPerDay,
                        type: .PostsPerDay)
            
            (sum, max, mean, stdDev) = calculateStatistics(values: postSentiments)
            addPlotData(account: account, day: day, month: month, year: year,
                        sum: postPerDay,
                        type: .SentimentPerPost)
            

            bar.next()
        }
        print("done")
 
        try? context.save()
        print("Completed the calculation of plot data.")
    }
    
    private func calculateStatistics(values:[Int]) -> (sum:Double, max:Double, mean:Double, stdDev:Double) {
        let sum = Double(values.reduce(0, +))
        let n = Double(values.count)
        let max = Double(values.max() ?? 0)
        let mean = sum / n
        let variance = values.reduce(0, { $0 + pow(Double($1) - mean, 2) }) / n
        let stdDev = sqrt(variance)
        return (sum,max, mean, stdDev)
    }
    
    private func calculateStatistics(values:[Double]) -> (sum:Double, max:Double, mean:Double, stdDev:Double) {
        let sum = Double(values.reduce(0, +))
        let n = Double(values.count)
        let max = Double(values.max() ?? 0)
        let mean = sum / n
        let variance = values.reduce(0, { $0 + pow(Double($1) - mean, 2) }) / n
        let stdDev = sqrt(variance)
        return (sum,max, mean, stdDev)
    }

    
    private func getNumberOfPosts(day:Int, month:Int, year:Int, account:Account) -> Int {
        let fetchRequest: NSFetchRequest<Post> = Post.fetchRequest()
        let predicate = NSPredicate(format:"account == %@ and day == %@ AND month == %@ AND year == %@",
                                    account,
                                    NSNumber(value:day),
                                    NSNumber(value:month),
                                    NSNumber(value:year))
        fetchRequest.predicate = predicate
        if let n = try? context.count(for: fetchRequest) {
            return n
        }
        return 0
    }
    
    private func addPlotData(account: Account,
                             day:Int, month:Int, year:Int, sum:Double,
                             mean:Double=0.0, stdDev:Double=0.0, max:Double=0.0,
                             type: PlotDataEnum) {
        let pd = PlotData(context: context)
        account.addToPlotData(pd)
        pd.account = account
        pd.max = max
        pd.sum = sum
        pd.standardDeviation = stdDev
        pd.mean = mean
        pd.day = Int16(day)
        pd.month = Int16(month)
        pd.year = Int16(year)
        pd.name = "Replies per posts on day"
        try? context.save()
    }
        
        
    
    private func getAllRepliesByDate(day:Int, month:Int, year:Int, account:Account) -> Int {
        let fetchRequest: NSFetchRequest<Post> = Post.fetchRequest()
        let predicate = NSPredicate(format:"day == %@ AND month == %@ AND year == %@",
//                                    account,
                                    NSNumber(value:day),
                                    NSNumber(value:month),
                                    NSNumber(value:year))
        fetchRequest.predicate = predicate
        
        if let posts = try? context.fetch(fetchRequest) {
            return posts.filter{isChildOf(child:$0, account:account)}.count
        }
        return 0
    }
    
    private func isChildOf(child:Post, account:Account) -> Bool {
        if child.account == account { return true }
        if child.account != nil { return false }
        if child.parent == nil { return false }
        return isChildOf(child: child.parent!, account: account)
    }
    
    private func getAllRepliesToPostOn(day:Int, month:Int, year:Int, account:Account) -> [Int] {
        let predicate = NSPredicate(format:"account == %@ AND day == %@ AND month == %@ AND year == %@",
                                    account,
                                    NSNumber(value:day),
                                    NSNumber(value:month),
                                    NSNumber(value:year))
        let fetchRequest: NSFetchRequest<Post> = Post.fetchRequest()
        fetchRequest.predicate = predicate

        if let posts = try? context.fetch(fetchRequest) {
            return posts
                .map{$0.statistics?.totalNumberOfReplies ?? 0}
                .map{Int($0)}
        }
        return []
    }
    
    private func getAllSentimentsToPostOn(day:Int, month:Int, year:Int, account:Account) -> [Double] {
        let predicate = NSPredicate(format:"account == %@ AND day == %@ AND month == %@ AND year == %@",
                                    account,
                                    NSNumber(value:day),
                                    NSNumber(value:month),
                                    NSNumber(value:year))
        let fetchRequest: NSFetchRequest<Post> = Post.fetchRequest()
        fetchRequest.predicate = predicate

        guard let posts = try? context.fetch(fetchRequest) else {
            return []
        }
        
        // Extract sentiments from posts
        let sentiments = posts.compactMap { $0.sentiments }.flatMap { $0 }
        
        // Filter sentiments with the desired tool and extract scores
        let filteredScores = sentiments.compactMap { sentiment in
            (sentiment as AnyObject).tool == SentimentAnalysisTool.NLTagger.stringValue ? (sentiment as AnyObject).score!: nil
        }
        
        return filteredScores
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

