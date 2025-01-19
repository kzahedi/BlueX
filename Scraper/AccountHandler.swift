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
    public let accounts : [Account]

    let context = CliPersistenceController.shared.container.viewContext
    
    
    private init(){
        let fetchRequest: NSFetchRequest<Account> = Account.fetchRequest()
        do {
            self.accounts = try context.fetch(fetchRequest)
        } catch {
            print("Cannot access accounts")
            exit(-1)
        }
    }
    
    public func printAccountInformation(){
        for account in accounts { print(account) }
    }
}
