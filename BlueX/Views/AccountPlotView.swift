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
//            PlotsPerDay(viewModel: viewModel)
//            RepliesPerDay(viewModel: viewModel)
            PlotsRepliesPerDay(viewModel: viewModel)
            AvgRepliesPerDay(viewModel: viewModel)
            ReplyTreeDepth(viewModel: viewModel)
            SentimentPerDay(viewModel: viewModel)
        }
    }
}

struct PlotsRepliesPerDay: View {
    @ObservedObject var viewModel: StatisticsModel
    
    var body: some View {
        GroupBox("Posts and replies per day") {
            Chart {
                ForEach(viewModel.plotsRepliesDataPoints) { dataPoint in
                    BarMark(x: .value("Month", dataPoint.date, unit:.day),
                            y: .value("Count", dataPoint.plotValue))
                    .foregroundStyle(by: .value("Series", dataPoint.series))
                    .position(by: .value("Series", dataPoint.series))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                }
            }
            //        .chartForegroundStyleScale([
            //            "Plots per day": .blue,
            //            "Replies per day": .orange
            //        ])
            //        .chartLegend(position: .top, alignment: .leading, spacing: 8)
            .chartXScale(domain: viewModel.xMin...viewModel.xMax)
            .frame(width:1000, height:300)
            .background(Color.black)
            .padding()
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

struct AvgRepliesPerDay: View {
    @ObservedObject var viewModel: StatisticsModel

    var body: some View {
        GroupBox("Replies per day") {
            Chart {
                ForEach(viewModel.avgRepliesPerDay) { dataPoint in
                    LineMark(x: .value("Month", dataPoint.day, unit:.day),
                            y: .value("Count", dataPoint.count),
                             series: .value("Type", "Avg number of replies"))
                    .foregroundStyle(by: .value("Type", "Avg number of replies"))
                }
                .foregroundStyle(Color.pink)
                ForEach(viewModel.maxRepliesPerDay) { dataPoint in
                    LineMark(x: .value("Month", dataPoint.day, unit:.day),
                            y: .value("Count", dataPoint.count),
                             series: .value("Type", "Max number of replies"))
                    .foregroundStyle(by: .value("Type", "Max number of replies"))
                }
            }
            .chartForegroundStyleScale(["Avg number of replies": .orange, "Max number of replies": .indigo])
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
        GroupBox("Reply tree depth") {
            Chart {
                ForEach(viewModel.replyTreeDepthPerDay) { dataPoint in
                    LineMark(x: .value("Month", dataPoint.day, unit:.day),
                             y: .value("Count", dataPoint.count),
                             series: .value("Type", "Avg Reply Tree Depth"))
                    .foregroundStyle(by: .value("Type", "Avg Reply Tree Depth"))
                }
                .foregroundStyle(Color.orange)
                ForEach(viewModel.maxReplyTreeDepthPerDay) { dataPoint in
                    LineMark(x: .value("Month", dataPoint.day, unit:.day),
                             y: .value("Count", dataPoint.count),
                             series: .value("Type", "Max Reply Tree Depth"))
                    .foregroundStyle(by: .value("Type", "Max Reply Tree Depth"))
                }
                .foregroundStyle(Color.indigo)
            }
            .chartForegroundStyleScale(["Avg Reply Tree Depth": .orange, "Max Reply Tree Depth": .indigo])
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
            .chartXScale(domain: viewModel.xMin...viewModel.xMax)
            .frame(width:1000, height:200)
            .background(Color.black)
            .padding()
        }
    }
}

