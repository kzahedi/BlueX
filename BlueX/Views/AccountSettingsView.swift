//
//  AccountSettings.swift
//  BlueX
//
//  Created by Keyan Ghazi-Zahedi on 03.01.25.
//

import Foundation
import SwiftUI

struct AccountSettingsView: View {
    @ObservedObject var viewModel: AccountViewModel
    @EnvironmentObject var taskManager: TaskManager
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ScrollView {
                VStack(spacing: 20) {
                    // BlueSky Account Information Section
                    blueSkyAccountInformation()
                    scrapingSettings()
                    scrapingInformation()
                    actionsView()
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
    
    private func actionsView() -> some View {
        return SectionCard(title: "Actions") {
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
                    .disabled(taskManager.isReplyScraperRunning)
                    .buttonStyle(.borderedProminent)
                }
                if taskManager.isReplyScraperRunning {
                    HStack {
                        ProgressView("Reply Trees Progress",
                                     value: taskManager.replyTreeProgress)
                    }
                }
                HStack {
                    Text("Calculate sentiments")
                    Spacer()
                    Button("Run") {
                        calculateSentiments()
                    }
                    .disabled(taskManager.isCalculatingSentiments)
                    .buttonStyle(.borderedProminent)
                }
                if taskManager.isCalculatingSentiments {
                    HStack {
                        ProgressView("Sentiments Progress",
                                     value: taskManager.calcualtedSentimentsProgress)
                    }
                }
                HStack {
                    Text("Calculate statistics")
                    Spacer()
                    Button("Run") {
                        calculateStatistics()
                    }
                    .disabled(taskManager.isCalculatingStatistics)
                    .buttonStyle(.borderedProminent)
                }
                if taskManager.isCalculatingStatistics {
                    HStack {
                        ProgressView("Statistics Progress",
                                     value: taskManager.calcualteStatisticsProgress)
                    }
                }
            }
            .padding(.horizontal)
            .frame(width: 400)
        }
    }
    
    private func blueSkyAccountInformation() -> some View {
        return SectionCard(title: "BlueSky Account Information") {
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
    }
    
    private func scrapingSettings() -> some View {
        return SectionCard(title: "Scraping Settings") {
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
                    Text("Is active")
                    Spacer()
                    Toggle("", isOn: $viewModel.isActive)
                        .onChange(of:viewModel.isActive){ viewModel.save()}
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
    }
    
    private func scrapingInformation() -> some View {
        return SectionCard(title: "Scraping Information") {
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
    
    private func runFeedScraping() {
        viewModel.updateAccount()
        taskManager.runFeedScraper(did:viewModel.account.did!,
                                   name:viewModel.account.displayName!,
                                   earliestDate: viewModel.account.startAt!,
                                   force: viewModel.account.forceFeedUpdate)
    }
    
    private func runReplyScraping() {
        viewModel.updateAccount()
        taskManager.runReplyScraper(did:viewModel.account.did!,
                                    name:viewModel.account.displayName!,
                                   earliestDate: viewModel.account.startAt!,
                                   force: viewModel.account.forceFeedUpdate)
    }
    
    private func calculateStatistics() {
        viewModel.updateAccount()
        taskManager.calculateStatistics(did:viewModel.account.did!,
                                        name:viewModel.account.displayName!)
    }
    
    private func calculateSentiments() {
        viewModel.updateAccount()
        taskManager.calculateSentiments(did:viewModel.account.did!,
                                        name:viewModel.account.displayName!)
    }

}

