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
    @Published var followersCount : String
    @Published var followsCount : String
    @Published var postsCount : String

    let account: Account
    let context: NSManagedObjectContext
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
        
        self.followersCount = "0"
        self.followsCount = "0"
        self.postsCount = "0"
        
        self.timestampFeed = self.getDate(from:account.timestampFeed)
        self.timestampReplyTrees = self.getDate(from:account.timestampReplyTrees)
        self.timestampSentiment = self.getDate(from:account.timestampSentiment)
        self.timestampStatistics = self.getDate(from:account.timestampStatistics)
        
        updateCountsFromHistory()
    }
    
    func updateAccount() {
        let r = resolveDID(handle: handle)
        if r != nil {
            did = r!
            let profile = resolveProfile(did: did)
            if profile != nil {
                handle = profile!.handle
                displayName = profile!.displayName
                followsCount = String(profile!.followsCount)
                followersCount = String(profile!.followersCount)
                postsCount = String(profile!.postsCount)
                
                let newAccountHistory = AccountHistory(context: self.context)
                newAccountHistory.accountID = account.id
                newAccountHistory.followersCount = Int64(profile!.followersCount)
                newAccountHistory.followsCount = Int64(profile!.followsCount)
                newAccountHistory.timestamp = Date()
                newAccountHistory.postsCount = Int64(profile!.postsCount)
            }
        }
        save()
    }
    
    func save() {
        account.handle = handle
        account.displayName = displayName
        account.did = did
        account.forceFeedUpdate = forceFeedUpdate
        account.forceReplyTreeUpdate = forceReplyUpdate
        account.forceSentimentUpdate = forceSentimentUpdate
        account.forceStatistics = forceStatistics
        account.startAt = startDate.toStartOfDay()
        account.followsCount = Int64(followsCount) ?? 0
        account.followersCount = Int64(followersCount) ?? 0
        
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
    
    private func updateCountsFromHistory() {
        let fetchRequest: NSFetchRequest<AccountHistory> = AccountHistory.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "accountID == %@", account.id! as CVarArg)
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
        fetchRequest.fetchLimit = 1
        
        var followersCount: Int64 = 0
        var followsCount: Int64 = 0
        var postsCount: Int64 = 0
        
        do {
            let results = try context.fetch(fetchRequest)
            if results.first != nil {
                followsCount = results.first!.followsCount
                followersCount = results.first!.followersCount
                postsCount = results.first!.postsCount
            }
        } catch {
            print("Failed to fetch AccountHistory: \(error)")
        }
        self.followersCount = String(followersCount)
        self.followsCount = String(followsCount)
        self.postsCount = String(postsCount)
    }
}

struct AccountSettings: View {
    @ObservedObject var viewModel: AccountViewModel
    @EnvironmentObject var taskManager: TaskManager
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ScrollView {
                VStack(spacing: 20) {
                    // BlueSky Account Information Section
                    SectionCard(title: "BlueSky Account Information") {
                        VStack {
                            Form{
                                HStack{
                                    TextField("Handle", text: $viewModel.handle)
                                        .textFieldStyle(.roundedBorder)
                                    Button(action: viewModel.updateAccount) {
                                        Image(systemName: "circle.fill")
                                            .foregroundColor(.gray)
                                    }
                                    
                                }
                                TextField("Display Name", text: $viewModel.displayName)
                                    .textFieldStyle(.roundedBorder)
                                    .disabled(true)
                                    .foregroundColor(.white)
                                TextField("DID", text: $viewModel.did)
                                    .textFieldStyle(.roundedBorder)
                                    .disabled(true)
                                    .foregroundColor(.white)
                                TextField("Number of followers", text: $viewModel.followersCount)
                                    .textFieldStyle(.roundedBorder)
                                    .disabled(true)
                                    .foregroundColor(.white)
                                TextField("Number of follows", text: $viewModel.followsCount)
                                    .textFieldStyle(.roundedBorder)
                                    .disabled(true)
                                    .foregroundColor(.white)
                                TextField("Number of posts", text: $viewModel.postsCount)
                                    .textFieldStyle(.roundedBorder)
                                    .disabled(true)
                                    .foregroundColor(.white)
                            }
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
                                .onChange(of:viewModel.startDate){ viewModel.save()}
                            }
                            HStack {
                                Text("Force update of already processed feeds")
                                Spacer()
                                Toggle("", isOn: $viewModel.forceFeedUpdate)
                                    .onChange(of:viewModel.forceFeedUpdate){ viewModel.save()}
                            }
                            HStack {
                                Text("Rescrape all reply trees")
                                Spacer()
                                Toggle("", isOn: $viewModel.forceReplyUpdate)
                                    .onChange(of:viewModel.forceReplyUpdate){ viewModel.save()}
                            }
                            HStack {
                                Text("Force sentiment updates")
                                Spacer()
                                Toggle("", isOn: $viewModel.forceSentimentUpdate)
                                    .onChange(of:viewModel.forceSentimentUpdate){ viewModel.save()}
                            }
                            HStack {
                                Text("Force statistics updates")
                                Spacer()
                                Toggle("", isOn: $viewModel.forceStatistics)
                                    .onChange(of:viewModel.forceStatistics){ viewModel.save()}
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
                    SectionCard(title: "Trigger Actions") {
                        VStack(spacing: 15) {
                            HStack {
                                Text("Scrape account feed")
                                Spacer()
                                Button("Run") {
                                    runFeedScraping()
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(taskManager.isFeedScraperRunning)
                            }
                            if taskManager.isFeedScraperRunning {
                                HStack {
                                    ProgressView("Feed Scraping Progress",
                                                 value: taskManager.feedProgress)
                                }
                            }
                            HStack {
                                Text("Scrape reply trees")
                                Spacer()
                                Button("Run") {
                                    runReplyScraping()
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(taskManager.isReplyScraperRunning)
                            }
                            if taskManager.isReplyScraperRunning {
                                HStack {
                                    ProgressView("Reply Trees Progress",
                                                 value: taskManager.replyTreeProgress)
                                }
                            }
                            HStack {
                                Text("Calculate statistics")
                                Spacer()
                                Button("Run") {
                                    calculateStatistics()
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(taskManager.isCalculatingStatistics)
                            }
                            if taskManager.isCalculatingStatistics {
                                HStack {
                                    ProgressView("Statistics Progress",
                                                 value: taskManager.calcualteStatistics)
                                }
                            }
                            HStack {
                                Text("Calculate sentiments")
                                Spacer()
                                Button("Run") {
                                    calculateSentiments()
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(taskManager.isCalculatingSentiments)
                            }
                            if taskManager.isCalculatingSentiments {
                                HStack {
                                    ProgressView("Sentiments Progress",
                                                 value: taskManager.calcualtedSentiments)
                                }
                            }
                        }
                        .padding(.horizontal)
                        .frame(width: 400)
                    }
                }
                .padding()
            }
        }
        .frame(width: 600)
        .padding()
        .background(
            VisualEffectBlur(material: .sidebar, blendingMode: .withinWindow)
                .ignoresSafeArea()
        )
        .navigationTitle("Account Settings")
    }
    
    private func runFeedScraping() {
        taskManager.runFeedScraper(did:viewModel.account.did!,
                                   name:viewModel.account.displayName!,
                                   earliestDate: viewModel.account.startAt!,
                                   force: viewModel.account.forceFeedUpdate)
    }
    
    private func runReplyScraping() {
        taskManager.runReplyScraper(did:viewModel.account.did!,
                                    name:viewModel.account.displayName!,
                                   earliestDate: viewModel.account.startAt!,
                                   force: viewModel.account.forceFeedUpdate)
    }
    
    private func calculateStatistics() {
        taskManager.calculateStatistics(did:viewModel.account.did!,
                                        name:viewModel.account.displayName!)
    }
    
    private func calculateSentiments() {
        taskManager.calculateSentiments(did:viewModel.account.did!,
                                        name:viewModel.account.displayName!)
    }

}



#Preview {
    let previewContext = createPreviewContext()
    let fetchRequest: NSFetchRequest<Account> = Account.fetchRequest()
    fetchRequest.fetchLimit = 1
    
    let account: Account
    do {
        account = try previewContext.fetch(fetchRequest).first ?? Account(context: previewContext)
        account.id = UUID()
    } catch {
        fatalError("Failed to fetch preview account: \(error)")
    }
    
    return AccountSettings(viewModel: AccountViewModel(account: account, context: previewContext))
        .environment(\.managedObjectContext, previewContext)
}

