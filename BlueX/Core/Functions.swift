//
//  Functions.swift
//  Bluesent
//
//  Created by Keyan Ghazi-Zahedi on 26.12.24.
//

import Foundation
import CoreData






func notifyTaskCompletion(taskName: String, accountName: String) {
    sendNotification(
        title: "BlueX",
        subtitle: accountName,
        body: "\(taskName) has successfully finished."
    )
}

