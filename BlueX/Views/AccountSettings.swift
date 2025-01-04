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
        self.followsCount = String(account.followsCount)
        self.followersCount = String(account.followersCount)
 
        self.timestampFeed = self.getDate(from:account.timestampFeed)
        self.timestampReplyTrees = self.getDate(from:account.timestampReplyTrees)
        self.timestampSentiment = self.getDate(from:account.timestampSentiment)
        self.timestampStatistics = self.getDate(from:account.timestampStatistics)
    }
    
    func updateAccount() {
        print("hier 0")
        let r = resolveDID(handle: handle)
        if r != nil {
            print("hier 1")
            did = r!
            print("Received DID: \(did)")
            let profile = resolveProfile(did: did)
            if profile != nil {
                print("hier 2")
                handle = profile!.handle
                displayName = profile!.displayName
                print(displayName)
                followsCount = String(profile!.followsCount)
                followersCount = String(profile!.followersCount)
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
        account.startAt = startDate
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

