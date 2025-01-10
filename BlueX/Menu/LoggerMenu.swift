//
//  ProcessMenu.swift
//  BlueX
//
//  Created by Keyan Ghazi-Zahedi on 07.01.25.
//

import Foundation
import SwiftUI
import CoreData

struct LoggerMenu: Commands {

    init() {
    }
        
    var body: some Commands {
        CommandMenu("Logger") {
            Button("Open Logger") {
                LoggerWindowController.shared.showWindow(nil)
            }
        }
    }
}


