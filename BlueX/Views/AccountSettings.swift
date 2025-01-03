//
//  AccountSettings.swift
//  BlueX
//
//  Created by Keyan Ghazi-Zahedi on 03.01.25.
//

import Foundation
import SwiftUI
import CoreData

class AccountViewModel: ObservableObject {
    @Published var displayName: String
    @Published var handle: String
    @Published var did: String
    @Published var forceFeedUpdate: Bool
    @Published var forceReplyUpdate: Bool
    @Published var forceSentimentUpdate: Bool
    @Published var forceStatistics: Bool
    @Published var startDate: Date
    @Published var timestampFeed: String
    @Published var timestampReplyTrees: String
    @Published var timestampSentiment: String
    @Published var timestampStatistics: String
    
    private let account: Account
    private let context: NSManagedObjectContext
    let outputFormatter = DateFormatter()

    init(account: Account, context: NSManagedObjectContext? = nil) {
        self.account = account
        self.context = context ?? PersistenceController.shared.container.viewContext
        self.outputFormatter.dateFormat = "dd.mm.YYYY"

        
        // Initialize ViewModel properties from CoreData model
        self.displayName = account.displayName ?? ""
        self.handle = account.handle ?? ""
        self.did = account.did ?? ""
        self.forceFeedUpdate = account.forceFeedUpdate
        self.forceReplyUpdate = account.forceReplyTreeUpdate
        self.forceSentimentUpdate = account.forceSentimentUpdate
        self.forceStatistics = account.forceStatistics
        self.startDate = account.startAt ?? Date()
        self.timestampFeed = ""
        self.timestampReplyTrees = ""
        self.timestampSentiment = ""
        self.timestampStatistics = ""
 
        self.timestampFeed = self.getDate(from:account.timestampFeed)
        self.timestampReplyTrees = self.getDate(from:account.timestampReplyTrees)
        self.timestampSentiment = self.getDate(from:account.timestampSentiment)
        self.timestampStatistics = self.getDate(from:account.timestampStatistics)
    }
    
    // Save changes to CoreData
    func save() {
        account.displayName = displayName
        account.handle = handle
        account.did = did
        account.forceFeedUpdate = forceFeedUpdate
        account.forceReplyTreeUpdate = forceReplyUpdate
        account.forceSentimentUpdate = forceSentimentUpdate
        account.forceStatistics = forceStatistics
        account.startAt = startDate
        
        do {
            try context.save()
            print("Account updated successfully.")
        } catch {
            print("Failed to save account: \(error)")
        }
    }
    
    func getDate(from timestamp: Date?) -> String {
        if timestamp == nil {
            return "Not yet processed"
        }
        return self.outputFormatter.string(from:timestamp!)
    }
}

struct AccountSettings: View {
    @ObservedObject var viewModel: AccountViewModel
    
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Account Settings")
                .font(.title2)
                .bold()
                .padding(.bottom, 10)
            
            ScrollView {
                VStack(spacing: 20) {
                    // BlueSky Account Information Section
                    SectionCard(title: "BlueSky Account Information") {
                        VStack(spacing: 15) {
                            TextField("Handle", text: $viewModel.handle)
                                .textFieldStyle(.roundedBorder)
                                .padding(.horizontal)
                            TextField("Display Name", text: $viewModel.displayName)
                                .textFieldStyle(.roundedBorder)
                                .padding(.horizontal)
                                .disabled(true)
                            TextField("DID", text: $viewModel.did)
                                .textFieldStyle(.roundedBorder)
                                .padding(.horizontal)
                                .disabled(true)
                        }
                        .frame(width: 400)
                    }
                    
                    SectionCard(title: "Scraping Settings") {
                        VStack(spacing: 15) {
                            HStack {
                                Text("Start Date")
                                Spacer()
                                DatePicker("",
                                           selection: $viewModel.startDate,
                                           displayedComponents: [.date])
                                .datePickerStyle(.field)
                            }
                            HStack {
                                Text("Force update of already processed feeds")
                                Spacer()
                                Toggle("", isOn: $viewModel.forceFeedUpdate)
                            }
                            HStack {
                                Text("Rescrape all reply trees")
                                Spacer()
                                Toggle("", isOn: $viewModel.forceReplyUpdate)
                            }
                            HStack {
                                Text("Force sentiment updates")
                                Spacer()
                                Toggle("", isOn: $viewModel.forceSentimentUpdate)
                            }
                            HStack {
                                Text("Force statistics updates")
                                Spacer()
                                Toggle("", isOn: $viewModel.forceStatistics)
                            }
                        }
                        .padding(.horizontal)
                        .frame(width: 400)
                    }
                    SectionCard(title: "Scraping Information") {
                        VStack(spacing: 15) {
                            HStack {
                                Text("Feed update timestamp")
                                Spacer()
                                TextField("", text: $viewModel.timestampFeed)
                                    .frame(width:125)
                                    .disabled(true)
                                    .foregroundColor(.white)
                            }
                            HStack {
                                Text("Reply trees timestamp")
                                Spacer()
                                TextField("", text: $viewModel.timestampReplyTrees)
                                    .frame(width:125)
                                    .disabled(true)
                                    .foregroundColor(.white)
                            }
                            HStack {
                                Text("Sentiment anaylsis timestamp")
                                Spacer()
                                TextField("", text: $viewModel.timestampSentiment)
                                    .frame(width:125)
                                    .disabled(true)
                                    .foregroundColor(.white)
                            }
                            HStack {
                                Text("Statistics calculation timestamp")
                                Spacer()
                                TextField("", text: $viewModel.timestampStatistics)
                                    .frame(width:125)
                                    .disabled(true)
                                    .foregroundColor(.white)
                            }
                        }
                        .padding(.horizontal)
                        .frame(width: 400)
                    }                    
                    // Action Buttons
                    Divider()
                    HStack {
                        Spacer()
                        Button(action: viewModel.save) {
                            Text("Update")
                                .frame(maxWidth: 100)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        Spacer()
                    }
                }
                .padding()
            }
        }
        .frame(width: 600, height: .infinity)
        .padding()
        .background(
            VisualEffectBlur(material: .sidebar, blendingMode: .withinWindow)
                .ignoresSafeArea()
        )
        .navigationTitle("Account Settings")
    }
}

// MARK: - Preview
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
    
    return AccountSettings(viewModel: AccountViewModel(account: account, context: previewContext))
        .environment(\.managedObjectContext, previewContext)
}

