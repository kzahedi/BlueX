//
//  ProcessMenu.swift
//  BlueX
//
//  Created by Keyan Ghazi-Zahedi on 07.01.25.
//

import Foundation
import SwiftUI
import CoreData

struct ProcessesMenu: Commands {
    
    private var updateAllTasks = UpdateAllTasks.shared
    
    init() { }
        
    var body: some Commands {
        CommandMenu("Processes") {
            Button("Update All Tasks") {
                updateAllTasks.execute()
            }
        }
    }
}


