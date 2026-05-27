import Foundation
import SwiftData

@Model
final class CoordinatorState {
    var phase: String               // "idle"|"preparing"|"feed"|"thread"|"annotating"
    var currentAccountDID: String?
    var currentPostURI: String?
    var updatedAt: Date

    init(phase: String = "idle") {
        self.phase = phase
        self.currentAccountDID = nil
        self.currentPostURI = nil
        self.updatedAt = Date()
    }
}
