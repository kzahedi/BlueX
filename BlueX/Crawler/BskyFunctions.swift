//
//  Functions.swift
//  BlueX
//
//  Created by Keyan Ghazi-Zahedi on 05.01.25.
//

import Foundation
import CoreData



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
