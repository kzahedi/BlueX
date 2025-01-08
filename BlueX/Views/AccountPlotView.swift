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
    @ObservedObject var viewModel: AccountViewModel
    
    var body: some View {
        Text("Plot View for \(viewModel.account.displayName ?? "unknown account")")
            .font(.title)
            .padding()
    }
}
