//
//  AccountSettings.swift
//  BlueX
//
//  Created by Keyan Ghazi-Zahedi on 03.01.25.
//

import Foundation
import SwiftUI
import CoreData

struct AccountSettings: View {
    @Environment(\.managedObjectContext) var managedObjectContext
    
    private var account: Account
    
    @State private var displayName: String
    @State private var handle: String
    @State private var forceFeedUpdate: Bool
    @State private var forceReplyUpdate: Bool
    @State private var forceSentimentUpdate: Bool

    @State var text: String = "hello"
    
    var body: some View {
        Text("Account Settings")
        Form {
            
            Section {
                TextField("Display Name", text: $displayName)
                TextField("Handle", text: $handle)
                LabeledContent("did", value: "16.2")
            } header: {
                Text("BlueSky Account Information")
            }
            Section {
                Toggle(isOn: $forceFeedUpdate) {
                    Text("Force update of already processed feeds")
                }
                Toggle(isOn: $forceReplyUpdate) {
                    Text("Rescrape all reply trees")
                }
            } header: {
                Text("Update Settings")
            }
            Divider()
            Button("Update") {
                updateAccount()
            }
            .buttonStyle(.borderedProminent)
            
        }
    }
    
    private func updateAccount() {
        account.displayName = displayName // Update the Core Data object
        do {
            try managedObjectContext.save() // Save the changes to the persistent store
            print("Account updated successfully.")
        } catch {
            print("Failed to update account: \(error)")
        }
    }
    
    init(account: Account) {
        self.account = account
        self._displayName = State(initialValue: account.displayName ?? "")
        self._handle = State(initialValue: account.handle ?? "")
        self._forceFeedUpdate = State(initialValue: account.forceFeedUpdate)
//        self._forceReplyUpdate = State(initialValue: account.forceReplyTreeUpdate)
    }
}

#Preview {
    let previewContext = createPreviewContext()
    let fetchRequest: NSFetchRequest<Account> = Account.fetchRequest()
    fetchRequest.fetchLimit = 1
    
    let account: Account
    do {
        account = try previewContext.fetch(fetchRequest).first ?? Account(context: previewContext)
    } catch {
        fatalError("Failed to fetch preview account: \(error)")
    }
    
    return AccountSettings(account: account)
        .environment(\.managedObjectContext, previewContext)
}
