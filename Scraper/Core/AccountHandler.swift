//
//  AccountHandler.swift
//  BlueX
//
//  Created by Keyan Ghazi-Zahedi on 18.01.25.
//

import Foundation
import CoreData

class AccountHandler {
    static let shared : AccountHandler = AccountHandler()
    public var accounts : [Account]

    let context = CliPersistenceController.shared.container.viewContext
    
    private init(){
        let fetchRequest: NSFetchRequest<Account> = Account.fetchRequest()
        do {
            let a = try context.fetch(fetchRequest)
            self.accounts = Array(Set(a))
            self.accounts.sort(by: {$0.displayName! < $1.displayName!})
        } catch {
            print("Cannot access accounts")
            exit(-1)
        }
    }
    
    public func printAccountInformation(){
        for account in accounts { print(account) }
    }
}
