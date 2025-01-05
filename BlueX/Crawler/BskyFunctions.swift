//
//  Functions.swift
//  BlueX
//
//  Created by Keyan Ghazi-Zahedi on 05.01.25.
//

import Foundation
import CoreData

func getPost(uri:String, context:NSManagedObjectContext) -> Post {
    let fetchRequest: NSFetchRequest<Post> = Post.fetchRequest()
    fetchRequest.predicate = NSPredicate(format: "uri == %@", uri as CVarArg)
    fetchRequest.fetchLimit = 1
    
    do {
        let results = try context.fetch(fetchRequest)
        if results.first != nil {
            return results.first!
        }
    } catch {
        print("Failed to fetch AccountHistory: \(error)")
    }
    
    let post = Post(context: context)
    post.uri = uri
    post.id = UUID()
    return post
}

func getAccount(did:String, context:NSManagedObjectContext) throws -> Account? {
    let fetchRequest: NSFetchRequest<Account> = Account.fetchRequest()
    fetchRequest.predicate = NSPredicate(format: "did == %@", did as CVarArg)
    fetchRequest.fetchLimit = 1
    
    let results = try context.fetch(fetchRequest)
    if results.first != nil {
        return results.first!
    }
    return nil
}
