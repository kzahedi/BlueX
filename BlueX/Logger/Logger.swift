//
//  Logger.swift
//  BlueX
//
//  Created by Keyan Ghazi-Zahedi on 10.01.25.
//


import SwiftUI
import Combine

final class Logger: ObservableObject {
    static let shared = Logger()
    
    @Published var logs: [String] = []
    
    private init() {}
    
    func log(_ message: String) {
        DispatchQueue.main.async {
            self.logs.append(message)
        }
    }
}
