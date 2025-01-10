//
//  LoggerView.swift
//  BlueX
//
//  Created by Keyan Ghazi-Zahedi on 10.01.25.
//

import Foundation
import SwiftUI

struct LoggerView: View {
    @ObservedObject var logger = Logger.shared
    @State private var scrollToBottom: UUID? = nil
    
    var body: some View {
        VStack {
            Text("Logger")
                .font(.headline)
                .padding(.top)
            
            Divider()
            
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading) {
                        ForEach(logger.logs, id: \.self) { log in
                            Text(log)
                                .font(.system(.body, design: .monospaced))
                                .padding(.vertical, 2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(log) // Assign unique ID for each log
                        }
                    }
                    .padding()
                }
                .background(Color(NSColor.textBackgroundColor))
                .cornerRadius(8)
                .padding()
                .onChange(of: logger.logs) { 
                    if let lastLog = logger.logs.last {
                        DispatchQueue.main.async {
                            proxy.scrollTo(lastLog, anchor: .bottom)
                        }
                    }
                }
            }
            
            Button("Clear Logs") {
                logger.logs.removeAll()
            }
            .padding()
        }
        .frame(minWidth: 400, minHeight: 300)
    }
}
