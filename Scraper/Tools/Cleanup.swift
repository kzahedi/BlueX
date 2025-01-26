//
//  Cleanup.swift
//  BlueX
//
//  Created by Keyan Ghazi-Zahedi on 22.01.25.
//

import Foundation
import CoreData
import Progress

struct Cleanup {
    let context = CliPersistenceController.shared.container.viewContext
    let accountHandler : AccountHandler = AccountHandler.shared
    
    func run(doit:Bool = false, batchSize:Int = 1000) {
        cleanupDates(doit:doit)
        resetReplyTreeChecked(doit:doit)
        checkPostsToDelete(doit:doit, batchSize:batchSize)
        checkReplyTreesToDelete(doit:doit)
//        checkSentimentsWithoutPosts(doit:doit, batchSize:batchSize)
    }
    
    private func cleanupDates(doit:Bool=false) {
        print("Cleanup dates")
        let predicate = NSPredicate(format: "day == nil or month == nil or year == nil")
        let fetchRequest: NSFetchRequest<Post> = Post.fetchRequest()
        fetchRequest.predicate = predicate
        let count = try! context.count(for: fetchRequest)
        if doit == false {
            print("Found \(count) posts that have missing date assignments.")
        } else {
            print("Will add day, monty, and year to \(count) posts.")
            var bar = ProgressBar(count: count)
            bar.setValue(0)
            if let posts = try? context.fetch(fetchRequest) {
                for post in posts {
                    let (day, month, year) = post.createdAt!.dayMonthYear()
                    post.day = Int16(day)
                    post.month = Int16(month)
                    post.year = Int16(year)
                }
                try! context.save()
                bar.next()
            }
        }
    }
    
    private func checkReplyTreesToDelete(doit:Bool=false) {
        print("Delete reply trees")
        let predicate = NSPredicate(format: "replies.@count > 0 and rootURI == nil and parentURI == nil and replyTreeChecked == false")
        let fetchRequest: NSFetchRequest<Post> = Post.fetchRequest()
        fetchRequest.predicate = predicate
        let count = try! context.count(for: fetchRequest)
        if doit == false {
            print("Found \(count) reply trees that were started but not completed.")
        } else {
            print("Will delete \(count) reply trees that were started but not completed.")
            var bar = ProgressBar(count: count)
            bar.setValue(0)
            
            if let posts = try? context.fetch(fetchRequest) {
                for post in posts {
                    if let replies = post.replies as? Set<Post> {
                        for reply in replies {
                            self.context.delete(reply)
                        }
                    }
                }
                try! context.save()
                bar.next()
            }
        }
     }
    
    private func resetReplyTreeChecked(doit:Bool = false) {
        print("Resetting reply tree checked flag")
        let predicate = NSPredicate(format: "replyCount > 0 AND replies.@count == 0 and rootURI == nil and parentURI == nil and replyTreeChecked == true")
        let fetchRequest: NSFetchRequest<Post> = Post.fetchRequest()
        fetchRequest.predicate = predicate
        let count = try! context.count(for: fetchRequest)
        if doit == true {
            print("Found \(count) posts")
            var bar = ProgressBar(count: count)
            bar.setValue(0)
            
            if let posts = try? context.fetch(fetchRequest) {
                for post in posts {
                    post.replyTreeChecked = false
                }
                try! context.save()
                bar.next()
            }
        } else {
            print("Would reset \(count) posts")
        }
    }

    private func checkPostsToDelete(doit:Bool = false, batchSize:Int) {
        print("Delete posts without account")
        var offset:Int = 0
        
        let predicate = NSPredicate(format: "account == nil && parentURI == nil")
        let fetchRequest: NSFetchRequest<Post> = Post.fetchRequest()
        fetchRequest.predicate = predicate
        let count = try! context.count(for: fetchRequest)
        
        if doit == true {
            var bar = ProgressBar(count: count)
            bar.setValue(0)
            
            var batch : [Post] = []
            repeat {
                batch = getPostBatch(offset: offset, batchSize: batchSize, predicate:predicate)
                for post in batch {
                    self.context.delete(post)
                    bar.next()
                }
                offset += batchSize
            } while !batch.isEmpty
        } else {
            print("Would delete \(count) posts")
        }
    }
    
//    private func checkSentimentsWithoutPosts(batchSize:Int) {
//        print("Delete sentiments with missing posts")
//        let predicate = NSPredicate(format: "account == nil && parentURI == nil")
//        var offset:Int = 0
//        
//        let fetchRequest: NSFetchRequest<Post> = Post.fetchRequest()
//        fetchRequest.predicate = predicate
//        let count = try! context.count(for: fetchRequest)
//        
//        var bar = ProgressBar(count: count)
//        bar.setValue(0)
//  
//        var batch : [Post] = []
//        repeat {
//            batch = getBatch(offset: offset, batchSize: batchSize, predicate:predicate)
//            for post in batch {
////                self.context.delete(post)
//                bar.next()
//            }
//            offset += batchSize
//        } while !batch.isEmpty
//    }
    
    private func getPostBatch(offset:Int, batchSize:Int, predicate:NSPredicate) -> [Post] {
        let fetchRequest: NSFetchRequest<Post> = Post.fetchRequest()
        fetchRequest.predicate = predicate
        fetchRequest.fetchLimit = batchSize
        fetchRequest.fetchOffset = offset
        
        do {
            return try context.fetch(fetchRequest)
        } catch {
            return []
        }
    }
}
