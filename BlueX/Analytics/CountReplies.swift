//
//  Statistics.swift
//  Bluesent
//
//  Created by Keyan Ghazi-Zahedi on 28.12.24.
//

import Foundation
import NaturalLanguage
import CoreData

struct CountReplies {
    
    var context : NSManagedObjectContext? = nil
    
    public func runFor(did: String, progress: @escaping (Double) -> Void) throws {
        
        print("Counting replies per post")
        var n : Double = 0.0
        
        let account = try getAccount(did: did, context: self.context!)
        if account == nil {
            return
        }
        let rootNodes = try getRootNodes(accountID:account!.id!)
        let count = Double(rootNodes.count)
        
        print("Found \(rootNodes.count) root nodes")
        
        
        for post in rootNodes {
            n = n + 1
            progress(n/count)
            post.countAllReplies = 0
            post.replyTreeDepth = 0
            try self.context!.save()
        }
        print("Done with counting replies")
    }
    
    //    private func countReplies(document: ReplyTree, depth:Int = 0) -> (Int, Int) {
    //        var n = document.replies?.count ?? 0
    //        var d = depth
    //        for reply in document.replies ?? [] {
    //            let (i, child_depth) = countReplies(document: reply, depth:depth+1)
    //            n += i
    //            if child_depth > d {
    //                d = child_depth
    //            }
    //        }
    //        return (n, d)
    //    }
    
    
    func getRootNodes(accountID:UUID) throws -> [Post] {
        let fetchRequest: NSFetchRequest<Post> = Post.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "accountID == %@", accountID as CVarArg)
        let results = try self.context!.fetch(fetchRequest)
        return results
    }
    
}

