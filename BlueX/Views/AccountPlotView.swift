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
    @ObservedObject var viewModel: PlotPerDayModel
    
    var body: some View {
        PlotsPerDay(viewModel: viewModel)
    }
}

struct PlotsPerDay: View {
    @ObservedObject var viewModel: PlotPerDayModel

    var body: some View {
        Chart {
            ForEach(viewModel.dataPoints) { dataPoint in
                BarMark(x: .value("Month", dataPoint.day, unit:.day),
                        y: .value("Count", dataPoint.count))
            }
        }
        .chartXScale(domain: viewModel.xMin...viewModel.xMax)
        .frame(width:1000, height:200)
        .background(Color.black)
    }
}
