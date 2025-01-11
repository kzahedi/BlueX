//
//  AccountPlotView.swift
//  BlueX
//
//  Created by Keyan Ghazi-Zahedi on 08.01.25.
//

import Foundation
import SwiftUI
import CoreData
import Charts

struct AccountPlotView: View {
    @ObservedObject var viewModel: StatisticsModel
    
    var body: some View {
        ScrollView {
            PlotsPerDay(viewModel: viewModel)
            RepliesPerDay(viewModel: viewModel)
            ReplyTreeDepth(viewModel: viewModel)
            SentimentPerDay(viewModel: viewModel)
        }
    }
}

struct PlotsPerDay: View {
    @ObservedObject var viewModel: StatisticsModel
    
    var body: some View {
        GroupBox("Sum of posts per day") {
            Chart {
                ForEach(viewModel.postsPerDay) { dataPoint in
                    BarMark(x: .value("Month", dataPoint.day, unit:.day),
                            y: .value("Count", dataPoint.count))
                }
            }
            .chartXScale(domain: viewModel.xMin...viewModel.xMax)
            .frame(width:1000, height:200)
            .background(Color.black)
            .padding()
        }
    }
}

struct RepliesPerDay: View {
    @ObservedObject var viewModel: StatisticsModel

    var body: some View {
        GroupBox("Sum of replies per day") {
            Chart {
                ForEach(viewModel.repliesPerDay) { dataPoint in
                    BarMark(x: .value("Month", dataPoint.day, unit:.day),
                            y: .value("Count", dataPoint.count))
                }
                .foregroundStyle(Color.green)
            }
            .chartXScale(domain: viewModel.xMin...viewModel.xMax)
            .frame(width:1000, height:200)
            .background(Color.black)
            .padding()
        }
    }
}

struct ReplyTreeDepth: View {
    @ObservedObject var viewModel: StatisticsModel
    
    var body: some View {
        GroupBox("Average reply tree depth per day") {
            Chart {
                ForEach(viewModel.replyTreeDepthPerDay) { dataPoint in
                    BarMark(x: .value("Month", dataPoint.day, unit:.day),
                            y: .value("Count", dataPoint.count))
                }
                .foregroundStyle(Color.orange)
            }
            .chartXScale(domain: viewModel.xMin...viewModel.xMax)
            .frame(width:1000, height:200)
            .background(Color.black)
            .padding()
        }
    }
}

struct SentimentPerDay: View {
    @ObservedObject var viewModel: StatisticsModel
    
    var body: some View {
        GroupBox("Average post-sentiment per day") {
            Chart {
                ForEach(viewModel.sentimentPosts, id: \.day) { dataPoint in
                    LineMark(x: .value("Month", dataPoint.day, unit:.day),
                             y: .value("Count", dataPoint.count),
                             series: .value("Type", "Avg Sentiments Posts"))
                    .foregroundStyle(by: .value("Type", "Avg Sentiments Posts"))
                }
                ForEach(viewModel.sentimentReplies, id: \.day) { dataPoint in
                    LineMark(x: .value("Month", dataPoint.day, unit:.day),
                             y: .value("Count", dataPoint.count),
                             series: .value("Type", "Avg Sentiments Replies"))
                    .foregroundStyle(by: .value("Type", "Avg Sentiments Replies"))
                }
            }
            .chartForegroundStyleScale(["Avg Sentiments Posts": .green, "Avg Sentiments Replies": .blue])
            .chartLegend(position: .top, alignment: .leading, spacing: 8)
            .chartXScale(domain: viewModel.xMin...viewModel.xMax)
            .frame(width:1000, height:200)
            .background(Color.black)
            .padding()
        }
    }
}

