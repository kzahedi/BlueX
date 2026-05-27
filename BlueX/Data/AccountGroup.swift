import Foundation
import SwiftData

@Model
final class AccountGroup {
    var name: String
    var notes: String?
    @Relationship(deleteRule: .nullify) var accounts: [TrackedAccount]

    init(name: String, notes: String? = nil) {
        self.name = name
        self.notes = notes
        self.accounts = []
    }
}
